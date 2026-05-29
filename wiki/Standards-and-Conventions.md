# Standards and Conventions

This page documents the project structure, coding standards, naming conventions, and troubleshooting practices for `renderfarm/houdini-aws-portal`. Follow these when contributing scripts, creating issues, or extending the build pipeline.

---

## Project folder scaffold

```
houdini-aws-portal/
├── .env                          # Local secrets and config — gitignored, never commit
├── .gitignore                    # Ignores .env, *.pem
├── README.md                     # Quick-start and repo overview
│
├── ami/                          # Everything needed to build the worker AMI
│   ├── build.sh                  # Build orchestrator — runs scripts 01-06 in order
│   └── scripts/
│       ├── 01_system_prep.sh     # apt update, build deps, blacklist Nouveau
│       ├── 02_nvidia_drivers.sh  # NVIDIA 535 driver + nvidia-persistenced
│       ├── 03_zerotier.sh        # ZeroTier client install + network join
│       ├── 04_houdini.sh         # Houdini 21.0 install + houdini-ubl.service
│       ├── 04b_rclone_b2.sh      # rclone install + rclone-b2-renders.service
│       ├── 05_deadline_worker.sh # Deadline 10.4.2.3 worker install + config
│       └── 06_cleanup.sh         # Pre-snapshot: wipe keys, creds, caches, history
│
├── aws/                          # AWS helper scripts (run from workstation)
│   ├── launch_build_instance.sh  # Launch the g6e.4xlarge build instance
│   └── create_ami.sh             # Stop instance and call ec2:CreateImage
│
└── deadline/
    └── aws_portal_notes.md       # AWS Portal config reference (AMI ID, settings)
```

### Where new files go

| Type | Location |
|---|---|
| New AMI build script | `ami/scripts/NN_name.sh` (next number in sequence) |
| New AWS CLI helper | `aws/verb_noun.sh` |
| Architecture decisions or notes | `deadline/` or a new top-level `docs/` dir |
| Installer binaries | S3 bucket only — never in the repo |
| Credentials / tokens | AWS Secrets Manager only — never in the repo |

---

## Shell script standards

### Header (required on every script)

```bash
#!/usr/bin/env bash
# NN_script_name.sh
# One-line description of what this script does.
# Preconditions: what must be true before this runs.
```

### Logging

Every script appends to the shared build log:

```bash
LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1
echo "==> [NN] Script name started at $(date)"
```

Always use the `==> [NN]` prefix so `grep "==>"` gives a build timeline.

### Error handling

```bash
set -euo pipefail
```

Place this after the `exec` redirect. Each step should fail loudly rather than silently continue.

### Fatal errors in build.sh

The orchestrator gates on each script's exit code:

```bash
FATAL: <script_name>.sh failed — check /var/log/ami-build.log
```

Do not swallow errors with `|| true` unless the failure is genuinely non-fatal and documented with a comment explaining why.

### Shellcheck

All scripts must pass `shellcheck` with no errors before merging:

```bash
shellcheck ami/scripts/NN_script.sh
shellcheck ami/build.sh
```

### Idempotency

Scripts should check for their own completion where practical so re-runs after a reboot don't duplicate work. Example pattern:

```bash
if nvidia-smi &>/dev/null; then
    echo "==> [02] NVIDIA driver already installed, skipping"
    exit 0
fi
```

---

## Naming conventions

### AMI names

```
deadline-<DEADLINE_VERSION>-houdini-<HOUDINI_VERSION>-ubuntu<OS_SHORT>-<GPU_FAMILY>-v<N>
```

Example: `deadline-10.4.2.3-houdini-21.0-ubuntu22-l40s-v1`

Increment `v<N>` for each rebuild. Tag AMIs with:
- `DeadlineVersion`
- `HoudiniVersion`
- `CreatedAt` (ISO 8601)

### AMI build scripts

Numbered `NN_name.sh` where `NN` is zero-padded. Scripts run in strict numeric order. Use `b` suffix for parallel-concern scripts at the same stage (e.g. `04b_rclone_b2.sh` alongside `04_houdini.sh`).

### AWS resource names

| Resource | Convention | Example |
|---|---|---|
| Security group | `deadline-<purpose>-sg` | `deadline-ami-build-sg` |
| Key pair | `deadline-<purpose>` | `deadline-ami-build` |
| IAM role | `deadline-<purpose>-role` | `deadline-worker-role` |
| Instance profile | `deadline-<purpose>-profile` | `deadline-worker-profile` |
| S3 bucket | `renderfarm-<purpose>-<account_id>` | `renderfarm-installers-774538489810` |

### Secrets Manager paths

```
<service>/<key-name>
```

| Secret | Path |
|---|---|
| Houdini UBL license endpoint DNS | `houdini/license-endpoint-dns` |
| Backblaze B2 key ID | `backblaze/b2-key-id` |
| Backblaze B2 application key | `backblaze/b2-app-key` |
| ZeroTier API token | `zerotier/api-token` |

Never store the secret value in code comments, issue descriptions, or commit messages.

### Environment variables

Uppercase snake case. Prefix by service where ambiguous:

```
AWS_REGION, S3_BUCKET, HOUDINI_VERSION, HOUDINI_BUILD, B2_BUCKET
```

---

## `.env` file conventions

`.env` is gitignored. It holds local working values for the workstation session.

```bash
# AWS
AWS_REGION=us-west-2
AWS_PROFILE=default          # or deadline-portal for restricted operations

# Build instance
VPC_ID=vpc-xxxxxxxxxxxxxxxxx
SUBNET_ID=subnet-xxxxxxxxxxxxxxxx
SG_ID=sg-xxxxxxxxxxxxxxxxx

# S3
S3_BUCKET=renderfarm-installers-774538489810

# Houdini
HOUDINI_VERSION=21.0
HOUDINI_BUILD=CHANGE_ME       # e.g. 688 — set after uploading installer

# B2
B2_BUCKET=aoin-test
```

**Rules:**
- Never commit `.env`
- Never `echo` secret values to the terminal
- Use `source .env` at the start of workstation scripts
- When a value is unknown, set it to `CHANGE_ME` as a reminder

---

## Secrets management rules

| Location | Used for |
|---|---|
| AWS Secrets Manager | Runtime credentials fetched by EC2 workers at boot |
| `.env` (gitignored) | Workstation session values (non-secret config) |
| AWS CLI profile | IAM access keys — stored in `~/.aws/credentials`, never in `.env` |

**Never put in the repo:**
- API tokens
- Access keys
- Application secrets
- `.pem` files

**Boot-time secret pattern** (used by all service units):

```bash
SECRET=$(aws secretsmanager get-secret-value \
    --region "$AWS_REGION" \
    --secret-id "service/key-name" \
    --query SecretString --output text 2>/dev/null)

if [[ -z "$SECRET" || "$SECRET" == "PENDING" ]]; then
    echo "WARNING: service/key-name not set. Skipping."
    exit 0
fi
```

---

## Systemd service conventions

Boot services installed by AMI scripts follow this order:

```
network-online.target
    └── zerotier-one.service
        └── houdini-ubl.service     (fetches license endpoint DNS)
            └── rclone-b2-renders.service   (mounts B2)
                └── deadline10launcher.service
```

Service unit files live in `/etc/systemd/system/`. Override files (for `After=` ordering) go in `/etc/systemd/system/<service>.d/override.conf`.

Boot init scripts live in `/usr/local/sbin/` with mode `700` (root-only).

---

## GitLab conventions

### Issue structure

Every issue should have:
- A single clearly stated **scope** (one file, one AWS action, or one validation step)
- **Acceptance criteria** as a checkbox list with exact verifiable commands
- A **Blocked by** section (or "No blockers")

Tracker issues that coordinate child issues use the format:

```
**Tracker issue** — <description of what it coordinates>
## Child issues
| Issue | Scope | Can start |
```

### Labels

| Label | Meaning |
|---|---|
| `ami` | AMI build scripts |
| `aws` | AWS infrastructure/CLI actions |
| `deadline` | Deadline Monitor/Portal |
| `houdini` | Houdini install or licensing |
| `licensing` | UBL endpoint or license config |
| `networking` | ZeroTier |
| `storage` | B2/rclone |
| `gpu` | NVIDIA driver |
| `testing` | Validation/acceptance testing |
| `infrastructure` | IAM, VPC, SG, key pairs |
| `documentation` | Wiki, README |
| `needs-refinement` | Issue is too large or ambiguous — must be resolved before work starts |

### Milestones

| Milestone | What it covers |
|---|---|
| M1: Foundation | Quotas, AWS infra, installer uploads, credentials — all parallel, no EC2 needed |
| M2: AMI Scripts | All `ami/scripts/*.sh` code review — parallel, shellcheck must pass |
| M3: AMI Build | Launch build instance, run `build.sh`, validate phases A–E, snapshot |
| M4: Portal Go-Live | UBL endpoint, AWS Portal config, end-to-end test render |

Child issues belong to the milestone of their earliest possible start, not their parent's milestone.

---

## Troubleshooting

### Primary build log

All AMI scripts append here:

```bash
tail -f /var/log/ami-build.log
grep "==>" /var/log/ami-build.log   # see step timeline
grep "FATAL\|ERROR\|WARNING" /var/log/ami-build.log
```

### Systemd service logs

```bash
journalctl -u houdini-ubl.service
journalctl -u rclone-b2-renders.service
journalctl -u deadline10launcher.service
journalctl -u zerotier-one.service
```

### Common failure points and checks

| Symptom | Where to look |
|---|---|
| `nvidia-smi` not found after `02_nvidia_drivers.sh` | Nouveau still loaded — check reboot happened; `lsmod | grep nouveau` |
| `hython --version` exits with license error | Check `houdini-ubl.service` ran; `cat /etc/profile.d/houdini-license.sh`; verify `houdini/license-endpoint-dns` secret is not PENDING |
| ZeroTier stuck at `REQUESTING_CONFIGURATION` | Node not yet authorized — go to https://my.zerotier.com/network/d3ecf5726d14ac76 |
| B2 mount not visible at `/mnt/renders` | `journalctl -u rclone-b2-renders.service`; check `backblaze/b2-key-id` and `backblaze/b2-app-key` secrets |
| Deadline worker not appearing in Monitor | Check ZeroTier is `OK PRIVATE` first; then `journalctl -u deadline10launcher` |
| AWS CLI command fails with "not authorized" | Confirm you `source .env` and the profile has the right permissions; for worker scripts, check the IAM instance profile has `deadline-worker-secrets-read` policy |
| AMI build S3 download fails | Confirm `S3_BUCKET` is set in `.env` and `HOUDINI_BUILD` matches the uploaded filename |

### Re-running a failed build

`build.sh` detects completed steps via marker flags. After fixing the issue:

1. Re-run `sudo bash /tmp/ami/build.sh --repo-ip ... --s3-bucket ... --houdini-build ... --b2-bucket ...`
2. Completed steps are skipped; the failed step retries
3. If you need to force a step to re-run, remove its marker file (see `build.sh` for the flag locations)

---

## AMI rebuild checklist

Before creating a new AMI version:

- [ ] All M2 script issues closed or accepted
- [ ] `shellcheck` passes on all scripts
- [ ] `06_cleanup.sh` verified — no SSH host keys, creds, or history remain
- [ ] AMI named with incremented `v<N>`
- [ ] AMI ID recorded as a comment on the relevant GitLab issue
- [ ] `deadline/aws_portal_notes.md` updated with new AMI ID
- [ ] Wiki `AMI-Build` page script table is current

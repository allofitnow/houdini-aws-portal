# houdini-aws-portal — Agent Rules

This project builds a custom AWS EC2 AMI for bursting Houdini 21.0 render jobs
via Thinkbox Deadline 10.4.2.3 AWS Portal. Workers use Ubuntu 22.04, NVIDIA L40S
GPUs (g6e.4xlarge), ZeroTier networking, Deadline Cloud UBL licensing, and
Backblaze B2 storage via rclone.

Full standards reference: [[Standards-and-Conventions]] wiki page.

---

## Project layout

```
ami/build.sh              # orchestrator — runs scripts 01-06
ami/scripts/NN_name.sh    # numbered build scripts, strict execution order
aws/                      # workstation helper scripts
deadline/                 # Deadline/Portal notes and config references
.env                      # gitignored local config — never commit
```

New AMI scripts go in `ami/scripts/` with the next `NN` prefix.
New AWS CLI helpers go in `aws/verb_noun.sh`.

---

## Shell script rules (mandatory)

Every `ami/scripts/*.sh` and `ami/build.sh` must:

1. Start with `#!/usr/bin/env bash`
2. Include a comment header: filename, one-line purpose, preconditions
3. Redirect all output to the shared log:
   ```bash
   LOG=/var/log/ami-build.log
   exec >> "$LOG" 2>&1
   echo "==> [NN] Script name started at $(date)"
   ```
4. Use `set -euo pipefail` (after the exec redirect)
5. Pass `shellcheck` with zero errors before any issue is marked done
6. Check for idempotency where practical (detect already-completed state and skip)

Never use `|| true` to suppress errors without a comment explaining why.

---

## Secrets — hard rules

- **Never hardcode** credentials, tokens, or keys anywhere in the repo
- **Never commit** `.env`, `*.pem`, or any file containing live secrets
- Runtime secrets live in **AWS Secrets Manager** under `service/key-name`:
  - `houdini/license-endpoint-dns`
  - `backblaze/b2-key-id`, `backblaze/b2-app-key`
  - `zerotier/api-token`
- Boot scripts fetch secrets at runtime using:
  ```bash
  SECRET=$(aws secretsmanager get-secret-value \
      --region "$AWS_REGION" --secret-id "service/key-name" \
      --query SecretString --output text 2>/dev/null)
  if [[ -z "$SECRET" || "$SECRET" == "PENDING" ]]; then
      echo "WARNING: service/key-name not set. Skipping."
      exit 0
  fi
  ```
- `.env` is for workstation config only (non-secret values like VPC_ID, SG_ID)
- Unknown values in `.env` must be set to `CHANGE_ME` as a placeholder

---

## Naming conventions

| Thing | Pattern | Example |
|---|---|---|
| AMI | `deadline-<DL>-houdini-<HOU>-ubuntu<OS>-<GPU>-v<N>` | `deadline-10.4.2.3-houdini-21.0-ubuntu22-l40s-v1` |
| Build script | `NN_name.sh` zero-padded | `04_houdini.sh` |
| Security group | `deadline-<purpose>-sg` | `deadline-ami-build-sg` |
| IAM role | `deadline-<purpose>-role` | `deadline-worker-role` |
| Secrets path | `<service>/<key>` | `houdini/license-endpoint-dns` |

---

## Systemd boot order

Services must declare `After=` in this order:
```
zerotier-one → houdini-ubl → rclone-b2-renders → deadline10launcher
```

Boot init scripts go in `/usr/local/sbin/` with mode `700`.

---

## GitLab issue conventions

When creating or updating issues:
- **One issue = one file, one AWS action, or one validation step**
- Every issue needs: scope statement, checkbox AC with exact verifiable commands, Blocked-by section
- Use tracker issues (with child issue table) when coordinating multiple sub-tasks
- Apply `needs-refinement` if an issue mixes concerns or has no clear done-state
- Assign to the correct milestone:
  - M1 Foundation → pre-build setup, no EC2 needed
  - M2 AMI Scripts → script code review, shellcheck
  - M3 AMI Build → live build instance, validate phases A–E
  - M4 Portal Go-Live → UBL endpoint, Portal config, test render
- Child issues belong to their **earliest possible start** milestone

---

## Troubleshooting first steps

| Symptom | Check first |
|---|---|
| `nvidia-smi` missing | Reboot after `02_nvidia_drivers.sh`; `lsmod \| grep nouveau` |
| Houdini license error | `cat /etc/profile.d/houdini-license.sh`; verify secret not PENDING |
| ZeroTier `REQUESTING_CONFIGURATION` | Authorize node at my.zerotier.com/network/d3ecf5726d14ac76 |
| B2 not mounted | `journalctl -u rclone-b2-renders.service` |
| Worker missing from Monitor | ZeroTier must be `OK PRIVATE` first |

Build log: `grep "==>" /var/log/ami-build.log` for step timeline.

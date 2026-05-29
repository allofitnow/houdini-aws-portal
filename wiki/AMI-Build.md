# AMI Build Guide

The worker AMI is built by SSHing into a temporary `g6e.4xlarge` instance and running `ami/build.sh`. The build is split into numbered scripts that run in sequence.

---

## Prerequisites

Before running the build, complete the following:

| Prerequisite | Where |
|---|---|
| AWS infrastructure ready (VPC, SG, IAM) | Issue [#2](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/2) |
| S3 bucket with installers uploaded | See below |
| Secrets stored in Secrets Manager | [Credentials and Secrets](Credentials-and-Secrets.md) |
| G/VT Spot quota requested for us-west-2 | Issue [#1](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/1) |

### S3 installer bucket layout

```
s3://<YOUR_BUCKET>/installers/
  houdini-21.0.<BUILD>-linux_x86_64_gcc11.2.tar.gz
  DeadlineClient-10.4.2.3-linux-x64-installer.run
```

Download sources:
- **Houdini:** [SideFX Download Portal](https://www.sidefx.com/download/) — Linux 21.0 builds
- **Deadline:** [AWS Thinkbox Downloads](https://awsthinkbox.com) — Client 10.4.2.3 Linux x64

---

## Step 1 — Launch the build instance

```bash
# From your workstation (WSL Ubuntu)
cd /home/aoin/projects/houdini-aws-portal
./aws/launch_build_instance.sh
```

Edit `SUBNET_ID` and `SG_ID` in `launch_build_instance.sh` before running (see Issue [#2](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/2)).

The script outputs the instance ID and public IP.

---

## Step 2 — Copy scripts and connect

```bash
scp -i ~/.ssh/deadline-ami-build.pem -r ami ubuntu@<PUBLIC_IP>:/tmp/
ssh -i ~/.ssh/deadline-ami-build.pem ubuntu@<PUBLIC_IP>
```

---

## Step 3 — Run the build

```bash
sudo bash /tmp/ami/build.sh \
  --repo-ip   <ZEROTIER_IP_OF_DEADLINE_REPO> \
  --s3-bucket <YOUR_S3_BUCKET> \
  --houdini-build <BUILD_NUMBER> \
  --b2-bucket <YOUR_B2_BUCKET>
```

The build will pause after `01_system_prep.sh` and ask you to reboot (to activate the Nouveau blacklist). SSH back in after reboot and re-run the same command — it detects the completed step and continues from `02_nvidia_drivers.sh`.

The build also pauses after `03_zerotier.sh` and prints the ZeroTier node ID. Authorise it before pressing Enter to continue.

---

## Script reference

| Script | Issue | What it does |
|---|---|---|
| `01_system_prep.sh` | [#3](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/3) | `apt update/upgrade`, build deps, blacklist Nouveau |
| `02_nvidia_drivers.sh` | [#3](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/3) | NVIDIA 535 data center driver + persistence daemon |
| `03_zerotier.sh` | [#4](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/4) | ZeroTier client, join `d3ecf5726d14ac76`, print node ID |
| `04_houdini.sh` | [#5](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/5) | Houdini 21.0 silent install + `houdini-ubl.service` |
| `04b_rclone_b2.sh` | [#10](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/10) | rclone install + `rclone-b2-renders.service` |
| `05_deadline_worker.sh` | [#6](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/6) | Deadline 10.4.2.3 worker, pool `houdini-aws-gpu` |
| `06_cleanup.sh` | [#7](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/7) | Remove caches, SSH host keys, history, temp creds |

All scripts append to `/var/log/ami-build.log`.

---

## Step 4 — Validate

Before imaging, verify on the running instance (Issue [#8](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/8)):

```bash
nvidia-smi                          # L40S should appear
hython --version                    # should print Houdini 21.0.x
zerotier-cli info                   # check node ID and network
systemctl status deadline10launcher # should be enabled (not started yet)
ls /mnt/renders                     # B2 mount active after ZT auth
```

---

## Step 5 — Create the AMI

```bash
# From your workstation
./aws/create_ami.sh <INSTANCE_ID>
```

This stops the instance (clean shutdown) and calls `ec2:CreateImage`. The final AMI ID is printed — record it for use in Deadline AWS Portal (see Issue [#9](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/9) and `deadline/aws_portal_notes.md`).

---

## Conventions

- **Numbered scripts** — Scripts run in strict numeric order. Do not reorder.
- **Environment variables as arguments** — `build.sh` takes explicit flags rather than relying on shell environment to keep builds reproducible.
- **No credentials in AMI** — Scripts install service units that fetch secrets at boot. Nothing sensitive is written to disk before `06_cleanup.sh`, and `06_cleanup.sh` wipes `/etc/rclone/rclone.conf` and `/etc/sesi/sesinetd.conf` anyway.
- **Log to `/var/log/ami-build.log`** — Every script appends its own output there. Use `tail -f /var/log/ami-build.log` to watch progress.
- **Idempotent intent** — Each script checks for its own completion where practical (e.g. NVIDIA driver check in `build.sh`) so re-runs after a reboot don't duplicate work.

---

## AMI naming convention

```
deadline-<DEADLINE_VERSION>-houdini-<HOUDINI_VERSION>-ubuntu<OS_SHORT>-<GPU_FAMILY>-v<N>
```

Example: `deadline-10.4.2.3-houdini-21.0-ubuntu22-l40s-v1`

Increment `v<N>` for each rebuild. Tag AMIs with `DeadlineVersion`, `HoudiniVersion`, and `CreatedAt`.

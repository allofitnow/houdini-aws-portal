# Spot Fleet Renderfarm

Custom AMI build and infrastructure scripts for bursting Houdini 21.0 render jobs from an on-prem Thinkbox Deadline 10.4.2.3 repository to EC2 Spot instances via the Spot Event Plugin (SEP).

## Stack

| Component | Detail |
|---|---|
| Deadline | 10.4.2.3 (on-prem Windows RCS + Pulse, central repository) |
| Worker OS | Amazon Linux 2023 |
| Instance types | g4dn.xlarge, g6.xlarge (Spot) |
| Region | us-west-2 (single-region, manual failover to us-east-1) |
| Networking | ZeroTier overlay — workers reach RCS at 10.147.18.89:4433 |
| Houdini | 21.0 with AWS Deadline Cloud Usage-Based Licensing (UBL) |
| Render delivery | Backblaze B2 via rclone FUSE mount + post-task S3 upload |
| AMI | v7 — `ami-04f1f92230541947f` (us-west-2), `ami-0546816e7e513ad03` (us-east-1) |

## Architecture

```
Studio LAN (ATXRTX Windows)          AWS us-west-2
  Deadline RCS :4433 ──── ZeroTier ──── EC2 Spot Workers (AMI v7)
  MongoDB :27100                        AL2023 + NVIDIA + Houdini 21.0
  Pulse (SEP)                           rclone B2 mount, UBL licensing
      │
      └── B2 bucket: aoin-test (render output)
```

Workers auto-provision on boot: join ZeroTier, acquire UBL license, mount B2, connect to Deadline RCS, and start rendering. The SEP scales instances based on job queue depth.

Full documentation: **[Wiki](http://gitlab.someofitlater.com/renderfarm/spot-fleet-renderfarm/-/wikis/home)**

## Repository layout

```text
ami/
  build.sh                Orchestrates the full AMI build (run on EC2 build instance)
  ca.crt                  Root CA for RCS TLS (baked into AMI)
  scripts/
    01_system_prep.sh     dnf update, build deps, kernel-modules-extra, X11/GL libs
    02_nvidia_drivers.sh  NVIDIA driver + nvidia-persistenced
    03_zerotier.sh        ZeroTier client + auto-join systemd service
    04_houdini.sh         Houdini 21.0 install + houdini-ubl.service
    04b_rclone_b2.sh      rclone + B2 FUSE mount at /mnt/renders
    05_deadline_worker.sh Deadline 10.4.2.3 worker + deadline.ini (RCS over ZeroTier)
    06_auto_group.sh      Auto-group assignment (aws-spot / aws-spot-east by region)
    06_cleanup.sh         Pre-snapshot: wipe keys, creds, caches, history
    07_s3_output_sync.sh  Post-task frame upload script + /tmp/renders setup
    s3_upload_frame.sh    Per-frame upload to B2 after render completes
aws/
  launch_build_instance.sh  Launch a temporary GPU build instance
  create_ami.sh             Stop instance and create a region-local AMI
test/
  Tester.hiplc              Test scene for render validation
```

## Prerequisites

- AWS CLI configured with credentials for account 774538489810
- Key pair `deadline-ami-build` in the build region
- IAM instance profile `deadline-worker-profile` (Secrets Manager read, S3, CloudWatch)
- Spot fleet role `aws-ec2-spot-fleet-tagging-role`
- Houdini 21.0 Linux installer in `s3://<bucket>/installers/`
- Deadline 10.4.2.3 Linux client installer in the same bucket
- Secrets Manager entries:
  - `houdini/zerotier-api-token`
  - `houdini/license-endpoint-dns`
  - `backblaze/b2-key-id`
  - `backblaze/b2-app-key`

## Build a worker AMI

### 1. Launch build instance

```bash
./aws/launch_build_instance.sh \
  --region us-west-2 \
  --subnet-id <BUILD_SUBNET_ID> \
  --sg-id <BUILD_SECURITY_GROUP_ID>
```

### 2. Copy scripts and run the build

```bash
scp -i ~/.ssh/deadline-ami-build.pem -r ami ubuntu@<PUBLIC_IP>:/tmp/
ssh -i ~/.ssh/deadline-ami-build.pem ubuntu@<PUBLIC_IP>

sudo bash /tmp/ami/build.sh \
  --s3-bucket <YOUR_BUCKET> \
  --houdini-build <BUILD_NUMBER> \
  --aws-region us-west-2
```

Reboot when prompted (Nouveau blacklist activation), then re-run `build.sh` to continue.

### 3. Create the AMI

```bash
./aws/create_ami.sh <INSTANCE_ID> --region us-west-2
```

Copy the resulting AMI to us-east-1 for failover, or rebuild it there.

## Spot Event Plugin management

SEP configuration is managed via `spotctl` (installed at `~/.local/bin/spotctl`):

```bash
spotctl show                      # View current config
spotctl enable                    # Enable the SEP (Global Enabled)
spotctl set max-workers 5         # Set target capacity
spotctl set spot-price 0.80       # Set max spot bid
spotctl set instance-types g6.xlarge,g4dn.xlarge
spotctl failover enable           # Add us-east-1 failover region
spotctl failover disable          # Back to single-region
```

All commands support `--dry-run`. Config changes require a Pulse restart to take effect.

See the [SEP Configuration & Operations](http://gitlab.someofitlater.com/renderfarm/spot-fleet-renderfarm/-/wikis/SEP-Configuration-and-Operations) wiki page for full details.

## GitLab

- Project: http://gitlab.someofitlater.com/renderfarm/spot-fleet-renderfarm
- Issues: http://gitlab.someofitlater.com/renderfarm/spot-fleet-renderfarm/-/issues
- Wiki: http://gitlab.someofitlater.com/renderfarm/spot-fleet-renderfarm/-/wikis/home

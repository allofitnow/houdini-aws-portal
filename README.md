# Houdini AWS Portal

Custom AMI build and infrastructure scripts for bursting Houdini 21.0 render jobs from an on-prem Thinkbox Deadline 10.4.2.3 repository to AWS EC2 Spot instances via two paths: direct-spawn spot workers and the Deadline AWS Portal fleet manager.

## Stack

| Component | Detail |
|---|---|
| Deadline | 10.4.2.3 (on-prem Windows RCS + Pulse, central repository) |
| Worker OS | Amazon Linux 2023 (AL2023) |
| Instance types | g6e.4xlarge (L40S GPU) — primary; g6.2xlarge–g6.16xlarge (Portal fleet) |
| Region | us-west-2 (single-region, manual failover to us-east-1) |
| Networking — Direct-spawn | Public subnet + IGW (free); ZeroTier overlay to RCS at 10.147.18.89:4433 |
| Networking — Portal | Portal-managed private subnet + NAT Gateway (~$32.40/mo idle) |
| Houdini | 21.0 with AWS Deadline Cloud Usage-Based Licensing (UBL) |
| Render delivery | Portal Asset Server (Portal path); rclone B2 mount (deprecated direct-spawn path) |
| AMI | `ami-0f70342f66dc80ddb` (us-west-2 worker AMI) |

> **Note:** The README previously listed `g4dn.xlarge`/`g6.xlarge` and AMI `ami-04f1f92230541947f` (v7).
> The current stack uses `g6e.4xlarge` (L40S) and `ami-0f70342f66dc80ddb`. The older types/AMIs
> are retained only for backward compatibility with the legacy `spotctl` SEP configuration.

## Architecture

```
Studio LAN (Windows RCS)                    AWS us-west-2
                                          ┌─────────────────────────────────────────┐
  Deadline RCS :4433 ─── ZeroTier ────────│── EC2 Spot Workers (AL2023 + L40S)       │
  MongoDB :27100         (overlay)         │   Direct-spawn: public subnet, IGW      │
  Pulse (SEP / Portal)                     │   Portal: private subnet, NAT Gateway   │
      │                                    │   Houdini 21.0 + UBL licensing          │
      └── Deadline AWS Portal ─────────────│── Portal Fleet Manager (CloudFormation)  │
           (manages private subnets)       └─────────────────────────────────────────┘
```

### Two worker spawning paths

| | Direct-spawn (`launch_spot_worker.sh`) | Portal (`launch_portal_worker_fleet.sh`) |
|---|---|---|
| Subnet | Public (`map-public-ip-on-launch=true`) | Portal-managed private |
| Outbound | IGW (free) | NAT Gateway (~$1.08/day) |
| ZeroTier | Yes — connects to RCS overlay | Not required (VPC routing) |
| UBL | Via ZeroTier to license endpoint | Via VPC endpoint (PrivateLink) |
| Render output | B2 via rclone (deprecated) | Portal Asset Server |

Full documentation: **[Wiki](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/wikis/home)**

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
    04b_rclone_b2.sh      rclone + B2 FUSE mount at /mnt/renders (deprecated)
    05_deadline_worker.sh Deadline 10.4.2.3 worker + deadline.ini (RCS over ZeroTier)
    06_auto_group.sh      Auto-group assignment (aws-spot / aws-spot-east by region)
    06_cleanup.sh         Pre-snapshot: wipe keys, creds, caches, history
    07_s3_output_sync.sh  Post-task frame upload script + /tmp/renders setup
    s3_upload_frame.sh    Per-frame upload to B2 after render completes
aws/
  launch_spot_worker.sh         Launch a direct-spawn spot worker (public subnet)
  launch_ready_spot_worker.sh   Launch with full health-check + UBL verify pipeline
  launch_portal_worker_fleet.sh Launch a Deadline Portal-managed fleet
  launch_build_instance.sh      Launch a temporary GPU build instance
  create_ami.sh                 Stop instance and create a region-local AMI
  portal_infra.sh               Portal infrastructure setup/teardown
  prepare_portal_region.sh      Prepare a region for Portal operations
  create_ubl_endpoint.sh        Create Deadline Cloud UBL license endpoint
  cleanup_all_infrastructure.sh Teardown orphaned AWS resources
  scan_gpu_capacity.sh          Scan spot capacity across regions/families
  compute_job_cost.sh           Estimate per-job render cost
  worker_secrets_policy.json    IAM policy for worker Secrets Manager access
deadline/
  aws_portal_notes.md           Deadline/Portal configuration notes
test/
  Tester.hiplc                  Test scene for render validation
```

## Prerequisites

- AWS CLI configured with credentials for account 774538489810
- Key pair `deadline-ami-build` in the build region
- IAM instance profile `deadline-worker-profile` (Secrets Manager read, S3, CloudWatch)
- Spot fleet role `aws-ec2-spot-fleet-tagging-role`
- Houdini 21.0 Linux installer in `s3://deadline-houdini-installers/installers/`
- Deadline 10.4.2.3 Linux client installer in the same bucket
- Secrets Manager entries:
  - `houdini/zerotier-api-token` (direct-spawn path only)
  - `houdini/license-endpoint-dns` (both paths)
  - `backblaze/b2-key-id` (deprecated B2/rclone path only)
  - `backblaze/b2-app-key` (deprecated B2/rclone path only)

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
scp -i ~/.ssh/deadline-ami-build.pem -r ami ec2-user@<PUBLIC_IP>:/tmp/
ssh -i ~/.ssh/deadline-ami-build.pem ec2-user@<PUBLIC_IP>

sudo bash /tmp/ami/build.sh \
  --s3-bucket deadline-houdini-installers \
  --houdini-build <BUILD_NUMBER> \
  --aws-region us-west-2
```

Reboot when prompted (Nouveau blacklist activation), then re-run `build.sh` to continue.

> **Note:** AL2023 uses `ec2-user` as the default SSH user. Prior builds used Ubuntu 22.04
> with `ubuntu@` — this is retained only in `deprecated/` scripts for reference.

### 3. Create the AMI

```bash
./aws/create_ami.sh <INSTANCE_ID> --region us-west-2
```

Copy the resulting AMI to us-east-1 for failover, or rebuild it there.

## Worker spawning

### Direct-spawn (spot workers)

```bash
# Simple launch
./aws/launch_spot_worker.sh \
  --region us-west-2 \
  --vpc-id <VPC_ID> \
  --count 3

# Full pipeline with health checks + UBL verification
./aws/launch_ready_spot_worker.sh \
  --region us-west-2 \
  --vpc-id <VPC_ID> \
  --count 3 \
  --instance-type g6e.4xlarge
```

Workers launch into **public subnets** (`map-public-ip-on-launch=true`), get public IPs,
and route outbound through the Internet Gateway (free). No NAT Gateway required.

### Deadline AWS Portal (fleet-managed)

```bash
# Prepare the region (VPC, security groups, UBL endpoint)
./aws/prepare_portal_region.sh --region us-west-2

# Launch a Portal-managed fleet
./aws/launch_portal_worker_fleet.sh \
  --region us-west-2 \
  --instance-types g6.4xlarge,g6.8xlarge \
  --count 5

# Teardown
./aws/portal_infra.sh --region us-west-2 --action stop
```

Portal creates its own VPC with **private subnets** and a **NAT Gateway** (~$32.40/month idle).
Always run `portal_infra.sh --action stop` after fleet cancellation to avoid NAT Gateway charges.

## Spot Event Plugin management (legacy)

SEP configuration is managed via `spotctl` (installed at `~/.local/bin/spotctl`):

```bash
spotctl show                      # View current config
spotctl enable                    # Enable the SEP (Global Enabled)
spotctl set max-workers 5         # Set target capacity
spotctl set spot-price 0.80       # Set max spot bid
spotctl set instance-types g6e.4xlarge,g6.xlarge
spotctl failover enable           # Add us-east-1 failover region
spotctl failover disable          # Back to single-region
```

All commands support `--dry-run`. Config changes require a Pulse restart to take effect.

See the [SEP Configuration & Operations](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/wikis/SEP-Configuration-and-Operations) wiki page for full details.

## Cost awareness

| Resource | Idle cost | Source |
|---|---|---|
| NAT Gateway (Portal VPC) | $0.045/hr = **$32.40/mo** | aws.amazon.com/vpc/pricing |
| VPC Interface endpoint | $0.01/hr/AZ | aws.amazon.com/privatelink/pricing |
| Public IPv4 (all, since Feb 2024) | $0.005/hr = **$3.60/mo** | aws.amazon.com/vpc/pricing |
| EBS gp3 volume | $0.08/GB/**month** | aws.amazon.com/ebs/pricing |
| VPC, subnet, IGW | **$0** (free) | aws.amazon.com/vpc/pricing |

Run `./aws/cleanup_all_infrastructure.sh --region us-west-2` to remove leaked resources.
See `aws/AWS-RESEARCH-NETWORKING-COSTS.md` for full pricing research.

## GitLab

- Project: http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal
- Issues: http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues
- Wiki: http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/wikis/home

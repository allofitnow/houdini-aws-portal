# houdini-aws-portal

Custom AMI build and AWS infrastructure scripts for bursting Houdini 21.0 render jobs from an on-prem Thinkbox Deadline 10.4.2.3 repository to EC2 Spot instances via AWS Portal or manual fallback workers.

## Stack

| Component | Detail |
|---|---|
| Deadline | 10.4.2.3 (on-prem Windows repo/RCS remains central) |
| Worker OS | Ubuntu 22.04 LTS |
| Instance types | GPU Spot capacity, typically g6/g6e where available |
| Regions | Region-configurable; `us-west-2` is the default/example only |
| Networking | AWS Portal Gateway per worker region; ZeroTier fallback for manual workers |
| Houdini | 21.0 with Deadline Cloud Usage-Based Licensing (UBL) |
| GPU render paths | Karma XPU, Redshift, Arnold, V-Ray |

## Multi-region model

GPU Spot capacity is not guaranteed in a single AWS region. Treat each worker region as an independent capacity cell:

- Keep one central on-prem Deadline Repository/RCS.
- Start one AWS Portal infrastructure stack in every AWS region where Portal-managed workers may run.
- Create one Deadline Cloud license endpoint in every worker region and store its DNS in that region's Secrets Manager.
- Copy or rebuild the worker AMI into every worker region.
- Configure region-local subnet and security group IDs for manual fallback workers.

Manual fallback worker scripts support per-region overrides using variables like `AMI_ID_US_EAST_1`, `SUBNET_ID_US_EAST_1`, `SG_ID_US_EAST_1`, and `HOUDINI_LICENSE_ENDPOINT_SECRET_ID_US_EAST_1`.

## Repository layout

```text
ami/
  build.sh              Orchestrates the full AMI build (run on the EC2 build instance)
  scripts/
    01_system_prep.sh   System update, dependencies, disable Nouveau
    02_nvidia_drivers.sh NVIDIA data center driver for L40S
    03_zerotier.sh      ZeroTier client install + join network
    04_houdini.sh       Houdini 21.0 silent install + regional UBL config
    05_deadline_worker.sh Deadline 10.4.2.3 Linux worker install
    06_cleanup.sh       Pre-image cleanup (caches, SSH host keys, history)
aws/
  launch_build_instance.sh      Launch a temporary GPU build instance
  create_ami.sh                 Stop the instance and create a region-local AMI
  portal_infra.sh               Status/stop guidance for per-region Portal stacks
  launch_ready_spot_worker.sh   Manual multi-region Spot fallback launcher
  launch_spot_worker.sh         Minimal legacy single-region manual launcher
  terminate_spot_worker.sh      Terminate manual workers in the selected region
deadline/
  aws_portal_notes.md           Configure Deadline AWS Portal with region-local AMIs
```

## Prerequisites

- AWS CLI configured with credentials for account 774538489810
- A key pair named `deadline-ami-build` in each build region, or pass `--key-name`
- IAM instance profile `deadline-worker-profile` with SSM, Secrets Manager read, and EC2 tag permissions
- Houdini 21.0 Linux installer tarball uploaded to `s3://YOUR_BUCKET/installers/`
- Deadline 10.4.2.3 Linux client installer uploaded to the same bucket
- Per-region Deadline Cloud license endpoint DNS stored in Secrets Manager, default secret name `houdini/license-endpoint-dns`

## Build and publish a worker AMI

### 1. Launch build instance

```bash
./aws/launch_build_instance.sh \
  --region us-west-2 \
  --subnet-id <BUILD_SUBNET_ID> \
  --sg-id <BUILD_SECURITY_GROUP_ID>
```

Override the base Ubuntu AMI per region with `--ami-id` or `AMI_ID`.

### 2. SSH in and run the build

```bash
ssh -i ~/.ssh/deadline-ami-build.pem ubuntu@<INSTANCE_PUBLIC_IP>
sudo bash /tmp/ami/build.sh \
  --aws-region us-west-2 \
  --repo-ip <ZEROTIER_IP_OF_DEADLINE_REPO> \
  --s3-bucket <YOUR_BUCKET> \
  --license-endpoint-secret-id houdini/license-endpoint-dns
```

### 3. Manually authorize the ZeroTier node

During the build, the node ID is printed. Authorize it at:
https://my.zerotier.com/network/d3ecf5726d14ac76

### 4. Validate, then create AMI

```bash
./aws/create_ami.sh <INSTANCE_ID> --region us-west-2
```

Copy the resulting AMI to every additional worker region or rebuild it there.

## Configure Deadline AWS Portal

See `deadline/aws_portal_notes.md` for the full operator workflow. The short version is:

1. In Deadline Monitor, enable Tools → Power User Mode.
2. Open View → New Panels → AWS Portal.
3. Start Portal infrastructure once per worker region.
4. In each region, start a Spot Fleet using the AMI copied into that same region.
5. Keep the Deadline Repository/RCS central; only Portal infrastructure, AMI IDs, UBL endpoints, subnets, and security groups are regional.

## Manual multi-region fallback workers

Use `aws/launch_ready_spot_worker.sh` when Portal capacity is unavailable or when testing a worker directly through ZeroTier/RCS:

```bash
READY_WORKER_REGIONS=us-west-2,us-east-1,eu-west-1 \
AMI_ID_US_EAST_1=ami-... \
SUBNET_ID_US_EAST_1=subnet-... \
SG_ID_US_EAST_1=sg-... \
HOUDINI_LICENSE_ENDPOINT_SECRET_ID_US_EAST_1=houdini/license-endpoint-dns \
./aws/launch_ready_spot_worker.sh
```

By default the launcher requires explicit network config and a usable regional UBL secret before attempting a launch.

## GitLab issues

Project: http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues

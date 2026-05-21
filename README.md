# houdini-aws-portal

Custom AMI build and AWS infrastructure scripts for bursting Houdini 21.0 render jobs
from an on-prem Thinkbox Deadline 10.4.2.3 repository to EC2 Spot instances via AWS Portal.

## Stack

| Component        | Detail                                       |
|------------------|----------------------------------------------|
| Deadline         | 10.4.2.3 (on-prem Windows repo)              |
| Worker OS        | Ubuntu 22.04 LTS                             |
| Instance type    | g6e.4xlarge (NVIDIA L40S 48 GB, 16 vCPU, 128 GB RAM) |
| Region           | us-west-2 (primary)                          |
| Networking       | ZeroTier overlay (network d3ecf5726d14ac76)  |
| Houdini          | 21.0 with Usage-Based Licensing (UBL)        |
| GPU render paths | Karma XPU, Redshift, Arnold, V-Ray           |

## Repository layout

```
ami/
  build.sh              Orchestrates the full AMI build (run on the EC2 build instance)
  scripts/
    01_system_prep.sh   System update, dependencies, disable Nouveau
    02_nvidia_drivers.sh NVIDIA data center driver for L40S
    03_zerotier.sh      ZeroTier client install + join network
    04_houdini.sh       Houdini 21.0 silent install + UBL config
    05_deadline_worker.sh Deadline 10.4.2.3 Linux worker install
    06_cleanup.sh       Pre-image cleanup (caches, SSH host keys, history)
aws/
  launch_build_instance.sh  Launch a temporary g6e.4xlarge build instance
  create_ami.sh             Stop the instance and create the AMI
deadline/
  aws_portal_notes.md   Steps to configure Deadline AWS Portal with the new AMI
```

## Prerequisites

- AWS CLI configured with credentials for account 774538489810
- A key pair named `deadline-ami-build` in us-west-2
- IAM instance profile `deadline-worker-profile` (SSM + Secrets Manager read)
- Houdini 21.0 Linux installer tarball uploaded to `s3://YOUR_BUCKET/installers/`
- Deadline 10.4.2.3 Linux client installer uploaded to same bucket
- UBL server token stored in AWS Secrets Manager as `houdini/ubl-token`

## Usage

### 1. Launch build instance

```bash
./aws/launch_build_instance.sh
```

### 2. SSH in and run the build

```bash
ssh -i ~/.ssh/deadline-ami-build.pem ubuntu@<INSTANCE_PUBLIC_IP>
sudo bash /tmp/build.sh --repo-ip <ZEROTIER_IP_OF_DEADLINE_REPO> --s3-bucket <YOUR_BUCKET>
```

### 3. Manually authorize the ZeroTier node

During the build, the node ID is printed. Authorize it at:
https://my.zerotier.com/network/d3ecf5726d14ac76

### 4. Validate (see issue #8), then create AMI

```bash
./aws/create_ami.sh <INSTANCE_ID>
```

### 5. Configure Deadline AWS Portal

See `deadline/aws_portal_notes.md`.

## GitLab issues

Project: http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues

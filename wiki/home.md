# houdini-aws-portal

**Burst Houdini 21.0 render jobs from an on-prem Thinkbox Deadline 10.4.2.3 farm to EC2 Spot instances via AWS Portal.**

This project provides the AMI build scripts, AWS helper scripts, and Deadline configuration documentation needed to set up GPU-accelerated cloud render workers that integrate into the existing render farm with no changes to the on-prem Deadline repository.

---

## At a glance

| | |
|---|---|
| **Deadline version** | 10.4.2.3 (on-prem Windows repository) |
| **Worker OS** | Ubuntu 22.04 LTS |
| **Instance type** | `g6e.4xlarge` — NVIDIA L40S 48 GB, 16 vCPU, 128 GB RAM |
| **Primary region** | us-west-2 (Oregon) |
| **Overlay network** | ZeroTier — network `d3ecf5726d14ac76` |
| **Renderer** | Houdini 21.0 with SideFX Usage-Based Licensing |
| **Render output** | Backblaze B2 mounted at `/mnt/renders` via rclone |
| **IAM user** | `deadline-portal` (least-privilege) |
| **AMI name** | `deadline-10.4.2.3-houdini-21.0-ubuntu22-l40s-v1` |

---

## Why this exists

The studio runs an on-prem render farm of 10 nodes (RTX A6000, 128 GB RAM, 16 cores each) managed by Thinkbox Deadline. For GPU-heavy Houdini jobs (Karma XPU, Redshift) during peak periods the local farm is insufficient. Rather than procure more hardware, EC2 Spot instances provide on-demand overflow capacity billed only while rendering.

Key design decisions:
- **Linux workers** — Houdini-only scope (no Notch/AE) enables Linux, which reduces cost, eliminates Windows licensing, and is the target OS for Deadline's Houdini conda packages.
- **ZeroTier overlay** — Workers join the existing render farm VPN instead of requiring a Site-to-Site VPN or RCS setup. MVP uses manual node authorisation; future work will automate it.
- **Backblaze B2 for input and output** — Cheaper than S3 for both scene storage and render frame storage. Mounted as a POSIX filesystem via rclone so workers read/write plain paths with no API integration.
- **No credentials in the AMI** — B2 keys, UBL token, and AWS credentials are pulled from Secrets Manager at boot and never baked into the image.
- **Capacity over location** — Instance allocation is region-agnostic within the limits of GPU spot availability. See [Instance Allocation](Instance-Allocation.md).

---

## Pages in this wiki

- [Instance Allocation](Instance-Allocation.md) — How workers are allocated across regions, groups, and Spot Fleets
- [B2 Render Workflow](B2-Render-Workflow.md) — Submit Houdini renders that read input from and write output to Backblaze B2
- [Architecture](Architecture.md) — Stack diagram, networking, storage, boot sequence
- [AMI Build](AMI-Build.md) — Step-by-step build guide and script conventions
- [Credentials and Secrets](Credentials-and-Secrets.md) — Where secrets live and how they are injected
- [Issue Index](Issue-Index.md) — All open and closed project issues with status

---

## Quick-start (tl;dr)

```
1. Resolve prerequisites in Issue-Index (#1, #2)
2. Upload installers to S3 and store secrets → Credentials-and-Secrets
3. ./aws/launch_build_instance.sh
4. ssh in, run: sudo bash /tmp/ami/build.sh --repo-ip <ZT_IP> --s3-bucket <BUCKET> --houdini-build <BUILD> --b2-bucket <BUCKET>
5. Authorize ZeroTier node at https://my.zerotier.com/network/d3ecf5726d14ac76
6. ./aws/create_ami.sh <INSTANCE_ID>
7. Configure Deadline AWS Portal → deadline/aws_portal_notes.md
```

---

## Repository

[http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal)

## GitHub mirror

Source mirror: [https://github.com/allofitnow/houdini-aws-portal](https://github.com/allofitnow/houdini-aws-portal)

This wiki is mirrored from the GitLab project wiki for GitHub visibility.
## Worker access quick reference

- SSH shell: connect as `ubuntu` to the worker ZeroTier IP, for example `ssh ubuntu@<zerotier-ip-of-worker>`.
- GUI/screen access: launch/provision with `INSTALL_DESKTOP=true`, then connect using the Amazon DCV client to `<zerotier-ip-of-worker>:8443` as user `ubuntu`.
- Full details: [DCV GUI + SSH worker access](AWS-Portal-RCS-and-Deadline-Cloud-UBL-Recovery.md#19-worker-operator-access-ssh-shell-and-amazon-dcv-gui).


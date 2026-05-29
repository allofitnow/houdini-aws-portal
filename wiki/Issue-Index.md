# Issue Index

All project issues:
[http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues)

---

## Milestone map

```
M1: Foundation ──────────────────────────────────────── (all parallel)
  #1  Quota us-west-2
  #2  AWS Infrastructure
    #12  IAM role + instance profile
    #13  Attach Secrets Manager policy  (blocked by #12)
    #14  Security group + key pair
    #15  Upload installers to S3
  #11 Wiki (ongoing)

          │ all of M1 complete
          ▼

M2: AMI Scripts ─────────────────────────────────────── (all parallel)
  #3  01_system_prep.sh + 02_nvidia_drivers.sh
  #4  03_zerotier.sh
  #5  04_houdini.sh  (Deadline Cloud UBL — endpoint created in #9)
  #6  05_deadline_worker.sh
  #7  ami/build.sh + 06_cleanup.sh
  #10 04b_rclone_b2.sh

          │ all of M2 scripts pass review
          ▼

M3: AMI Build ───────────────────────────────────────── (sequential)
  #8  Validate AMI (NVIDIA + Houdini + ZT + Deadline + B2 + test render)

          │ #8 complete  AND  #1 (quota) approved
          ▼

M4: Portal Go-Live ──────────────────────────────────── (sequential)
  #9  Deadline Cloud UBL endpoint (Houdini Engine + Karma) + AWS Portal config
```

---

## M1: Foundation

| # | Title | Type | Status |
|---|---|---|---|
| [#1](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/1) | Submit G/VT Spot quota increase for us-west-2 (160 vCPUs) | parent | Open |
| [#2](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/2) | Set up AWS infrastructure (SG, IAM, key pair) | parent | Open |
| [#12](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/12) | Create IAM role and instance profile | child of #2 | Open |
| [#13](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/13) | Attach Secrets Manager policy to role | child of #2 | Open |
| [#14](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/14) | Create security group and key pair | child of #2 | Open |
| [#15](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/15) | Upload Houdini + Deadline installers to S3 | child of #2 | Open |
| [#11](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/11) | Project wiki (ongoing) | ongoing | Open |

## M2: AMI Scripts

| # | Title | Type | Status |
|---|---|---|---|
| [#3](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/3) | 01_system_prep.sh + 02_nvidia_drivers.sh | parent | Open |
| [#4](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/4) | 03_zerotier.sh | parent | Open |
| [#5](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/5) | 04_houdini.sh + Deadline Cloud UBL licensing | parent | Open |
| [#6](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/6) | 05_deadline_worker.sh | parent | Open |
| [#7](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/7) | ami/build.sh + 06_cleanup.sh | parent | Open |
| [#10](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/10) | 04b_rclone_b2.sh | parent | Open |

## M3: AMI Build

| # | Title | Type | Status |
|---|---|---|---|
| [#8](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/8) | Validate AMI: NVIDIA, Houdini, ZT, Deadline, B2, test render | parent | Open |

## M4: Portal Go-Live

| # | Title | Type | Status |
|---|---|---|---|
| [#9](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/9) | Deadline Cloud UBL endpoint + AWS Portal configuration | parent | Open |

---

## Houdini licensing

Houdini 21.0 licensing uses **AWS Deadline Cloud UBL** — pay-per-use billed through AWS, no SideFX floating license purchase required.

- The old Thinkbox UBL Marketplace was decommissioned Sep 30 2025, but **AWS Deadline Cloud UBL is a separate, still-active service**
- Supported products include **Houdini Engine** and **Houdini Karma** (GPU renderer, tiered pricing)
- A Deadline Cloud license endpoint is created inside the worker VPC (`aws deadline create-license-endpoint`)
- Workers set `HOUDINI_LICENSE_SERVER` to the endpoint's VPC DNS at boot via `houdini-ubl.service`
- Endpoint DNS stored in Secrets Manager as `houdini/license-endpoint-dns`
- Required inbound on worker security group: TCP 1715–1717 from the endpoint
- Endpoint setup is part of issue #9 (M4: Portal Go-Live)

---

## Closed / won't do

| # | Title | Reason |
|---|---|---|
| [#16](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/16) | Generate SideFX API Key credentials | Superseded by Deadline Cloud UBL |
| [#17](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/17) | Update 04_houdini.sh for SideFX API Key | Superseded — script unchanged |

---

## Future / backlog

| Idea | Notes |
|---|---|
| Automate ZeroTier node approval | Use `zerotier/api-token` via ZeroTier Central API |
| Multi-region: us-east-1 | Quota already at 120; replicate AMI |
| Deadline Auto Scale idle timeout | 15–30 min to control cost |
| Spot interruption checkpoint | SIGTERM handler for re-queue |
| Secret rotation Lambda | Rotate B2 keys on schedule |

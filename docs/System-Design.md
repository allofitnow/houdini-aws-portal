# Houdini AWS Portal — System Design Specification

This document defines the **system boundary** of the houdini-aws-portal renderfarm.
It maps every platform boundary and the SDK/API interfaces that cross those edges.

The system is decomposed into **six platforms**. An edge exists wherever one platform
calls into another. Each edge documents: the transport, the SDK/API used, the auth
mechanism, and the data contract.

---

## Platform inventory

| # | Platform | What lives here | Trust boundary |
|---|----------|-----------------|----------------|
| **P1** | **On-prem Studio LAN** (Windows RCS host) | Deadline RCS, Repository DB (MongoDB), Event Plugins, Deadline Monitor, ZeroTier controller client | Studio firewall |
| **P2** | **AWS Cloud — EC2 Compute** | Spot worker instances, Portal fleet workers, Gateway instances, AMIs | AWS IAM + VPC SG |
| **P3** | **AWS Cloud — Managed Services** | Secrets Manager, S3 (installers), CloudFormation, IAM, SSM, Pricing API, CUR 2.0 / Athena | AWS IAM |
| **P4** | **Deadline Cloud (AWS-hosted)** | Deadline Cloud UBL license endpoints, metered product catalog | AWS IAM + Deadline Cloud API |
| **P5** | **External SaaS** | Backblaze B2 (render storage), ZeroTier coordination servers (my.zerotier.com), SideFX licensing servers | API key / token per service |
| **P6** | **Developer / Operator workstation** | AWS CLI, `deadlinecommand`, Git repo, GitLab, Houdini submitter | SSH key + GitLab PAT |

---

## System boundary diagram

```
┌─ P6: Operator Workstation ──────────────────────────────────────────────────┐
│                                                                              │
│  AWS CLI ───────────────────────────┐                                        │
│  deadlinecommand.exe ───────────────┤                                        │
│  Houdini 21.0 Submitter ────────────┤                                        │
│  Git repo (houdini-aws-portal) ─────┼──► GitLab (self-hosted)                │
│                                     │                                        │
│  .env (non-secret: VPC_ID, SG_ID)  │                                        │
└─────────────────────────────────────┼────────────────────────────────────────┘
                                      │
                    ┌─────────────────┼──────────────────────────────────┐
                    │                 │                                   │
                    ▼                 ▼                                   │
┌─ P1: On-prem Studio LAN ──────────────────────────────────────────────────┐ │
│                                                                            │ │
│  ┌──────────────────────────────────────┐                                  │ │
│  │  Deadline RCS (Windows host)          │                                  │ │
│  │  192.168.30.231 / ZeroTier 10.147.18.89:4433                          │ │
│  │                                       │                                  │ │
│  │  • Deadline Repository DB (MongoDB)   │                                  │ │
│  │  • Event Plugins (AWSPortal, SEP,     │                                  │ │
│  │    AwsJobCostObserver — future)       │                                  │ │
│  │  • deadlinecommand.exe                │                                  │ │
│  │  • WSL shell (scripts, cron)          │                                  │ │
│  └──┬──────┬──────┬──────────────────────┘                                  │ │
│     │      │      │                                                          │ │
│     │      │      │ ExtraInfo 1980-2000 (job metadata)                       │ │
│     │      │      ▼                                                          │ │
│     │      │  ┌──────────────────────────┐                                   │ │
│     │      │  │ Deadline Monitor (artist │                                   │ │
│     │      │  │ workstations on LAN)     │                                   │ │
│     │      │  └──────────────────────────┘                                   │ │
│     │      │                                                                 │ │
│     │      │ Deadline Python Event Plugin API (RepositoryUtils, JobUtils)    │ │
│     │      ▼                                                                 │ │
│     │  Event plugin callbacks (OnJobFinished, OnJobPended, etc.)             │ │
│     │                                                                        │ │
│     │ Deadline Remote Connection (TCP 4433 over ZeroTier)                    │ │
│     ▼                                                                        │ │
└─────┼────────────────────────────────────────────────────────────────────────┘
      │                        │                            │
      │ ZeroTier overlay       │ AWS API calls              │
      │ (network d3ecf572...)  │ (boto3 / aws CLI)          │
      │                        │                            │
      ▼                        ▼                            ▼
┌─ P5: ZeroTier ──────┐  ┌─ P3: AWS Managed Services ───────────────────────┐
│                      │  │                                                    │
│  ZT Controller       │  │  Secrets Manager ──── houdini/*, backblaze/*      │
│  my.zerotier.com     │  │  S3 ───────────────── deadline-houdini-installers│
│  API: REST + token   │  │  CloudFormation ──── Portal stacks               │
│                      │  │  IAM ──────────────── roles, policies            │
│  Member authorize/   │  │  SSM ──────────────── RunCommand                 │
│  delete via REST     │  │  EC2 Pricing ──────── GetProducts                │
│                      │  │  CUR 2.0 / Athena ── cost reconciliation         │
└──────────────────────┘  │  Deadline Cloud API─ list-license-endpoints      │
                          └────────────────────────────────────────────────────┘
      │                                                 │
      │ ZeroTier overlay (workers join ZT network)      │ IAM role / instance profile
      ▼                                                 ▼
┌─ P2: AWS Cloud — EC2 Compute ──────────────────────────────────────────────────┐
│                                                                                 │
│  ┌─────────────────────────────────────────┐  ┌─────────────────────────────┐ │
│  │  Direct-spawn Spot Worker               │  │  Portal Fleet Worker         │ │
│  │  (launch_spot_worker.sh /               │  │  (AWS Portal Spot Fleet)     │ │
│  │   launch_ready_spot_worker.sh)          │  │                              │ │
│  │                                          │  │                              │ │
│  │  Public subnet + IGW (free)             │  │  Private subnet + NAT GW     │ │
│  │  ZeroTier → RCS overlay                 │  │  Portal Gateway → RCS        │ │
│  │  B2 rclone mount (/mnt/renders)         │  │  Portal Asset Server          │ │
│  │  Deadline 10.4.2.3 worker               │  │  Deadline 10.4.2.3 worker    │ │
│  │  Houdini 21.0 + UBL                     │  │  Houdini 21.0 + UBL          │ │
│  │  AMI: ami-0f70342f66dc80ddb             │  │  AMI: region-local copy       │ │
│  │  Tag: DeadlineTrackedAWSResource=true   │  │  Tag: DeadlineTrackedAWS...   │ │
│  └─────────────────────────────────────────┘  └─────────────────────────────┘ │
│                                                                                 │
│  Boot sequence (systemd):                                                       │
│    1. network-online.target                                                    │
│    2. zerotier-one.service → joins d3ecf5726d14ac76 (direct-spawn only)        │
│    3. houdini-ubl.service → SecretsManager GetSecretValue → license DNS         │
│    4. rclone-b2-renders.service → SecretsManager GetSecretValue → B2 keys       │
│    5. deadline10launcher.service → connects to RCS                             │
└────────────────────────────────────────────────────────────────────────────────┘
       │                                              │
       │                                              │
       ▼                                              ▼
┌─ P5: Backblaze B2 ──────┐  ┌─ P4: Deadline Cloud UBL ──────────────────────┐
│                          │  │                                                  │
│  B2 bucket: aoin-test    │  │  License endpoint (VPC-endpoint)                │
│  /inputs/  (scene files) │  │  TCP 1715-1717                                  │
│  /outputs/ (render EXRs) │  │  Products: houdini-21.0, karma-21.0, mantra    │
│                          │  │  Billing: per-core-hour metered                │
│  API: S3-compatible      │  │                                                  │
│  Auth: B2 key ID + app   │  │  Managed by: create_ubl_endpoint.sh            │
│  key from Secrets Mgr    │  │  Discovery: AWS Deadline API                   │
│                          │  │                                                  │
└──────────────────────────┘  └──────────────────────────────────────────────────┘
```

---

## Edge catalogue

Each edge is a dependency crossing a platform boundary. Edges are grouped by the
calling platform.

### E1: Operator → Deadline RCS (P6 → P1)

| Property | Value |
|----------|-------|
| **Transport** | Deadline Remote Connection (TCP 4433) or local LAN |
| **SDK** | `deadlinecommand.exe` CLI, `Deadline.Scripting` Python (via Deadline Monitor) |
| **Auth** | None (LAN trust) or Deadline user auth |
| **Operations** | Submit jobs, query jobs/slaves, configure event plugins (SEP, AWSPortal), SetJobSetting, GetJobTasks |
| **CLI binary** | `/mnt/c/Program\ Files/Thinkbox/Deadline10/bin/deadlinecommand.exe` |
| **Python import** | `from Deadline.Scripting import RepositoryUtils` |

**Data contract:** Job objects with Pool, Group, ExtraInfo[0-99], ExtraInfo[1980-2000+], PluginName, FrameRange, TaskList (with SlaveName, StartTime, EndTime per task).

### E2: Operator → AWS (P6 → P3)

| Property | Value |
|----------|-------|
| **Transport** | HTTPS to `*.amazonaws.com` |
| **SDK** | AWS CLI v2, boto3 |
| **Auth** | AWS credentials (`~/.aws/credentials` or env vars), account `774538489810` |
| **Operations** | `ec2:RunInstances`, `ec2:DescribeInstances`, `ec2:DescribeSpotPriceHistory`, `ec2:TerminateInstances`, `ec2:DescribeAddresses`, `cloudformation:DescribeStacks`, `ssm:SendCommand`, `pricing:GetProducts`, `secretsmanager:GetSecretValue`, `athena:StartQueryExecution`, `deadline:ListLicenseEndpoints` |

**Data contract:** AWS API JSON responses. Spot price history entries. CUR 2.0 Athena query results. EC2 describe-instances JSON.

### E3: Operator → GitLab (P6 → self-hosted GitLab)

| Property | Value |
|---|---|
| **Transport** | SSH (git push/pull) + HTTPS (REST API) |
| **SDK** | `git`, curl to `http://gitlab.someofitlater.com/api/v4` |
| **Auth** | SSH ed25519 key (`deadline-mon-hermes`, GitLab key ID 19), PAT for API |
| **Operations** | Push/pull master, protect/unprotect branches, create/update wiki pages |

### E4: Deadline RCS → EC2 Workers (P1 → P2)

| Property | Value |
|---|---|
| **Transport** | TCP 4433 over ZeroTier overlay (direct-spawn) or Portal Gateway tunnel (Portal workers) |
| **SDK** | Deadline Remote Connection Protocol (Thinkbox proprietary) |
| **Auth** | RCS TLS certificates (DeadlineRCSServer.pem, DeadlineRCSClient.pem) |
| **Operations** | Task distribution, slave heartbeat, job status updates |

**Network paths differ by worker type:**

| Worker type | Path to RCS | Cost |
|---|---|---|
| Direct-spawn (public subnet) | ZeroTier overlay `10.147.18.89:4433` | Free (IGW) |
| Portal (private subnet) | Portal Gateway tunnel via NAT GW | ~$32.40/mo (NAT GW idle) |

### E5: EC2 Worker → Secrets Manager (P2 → P3)

| Property | Value |
|---|---|
| **Transport** | HTTPS to `secretsmanager.<region>.amazonaws.com` |
| **SDK** | AWS CLI (`aws secretsmanager get-secret-value`) in boot scripts |
| **Auth** | IAM instance profile (`deadline-worker-profile`) → `worker_secrets_policy.json` |
| **Permissions** | `secretsmanager:GetSecretValue` on `arn:aws:secretsmanager:*:774538489810:secret:houdini/*` and `backblaze/*` |
| **Secrets** | `houdini/license-endpoint-dns`, `houdini/zerotier-api-token`, `backblaze/b2-key-id`, `backblaze/b2-app-key` |

**Data contract:** `SecretString` field containing plaintext values. PENDING sentinel = not yet provisioned.

### E6: EC2 Worker → Deadline Cloud UBL (P2 → P4)

| Property | Value |
|---|---|
| **Transport** | TCP 1715-1717 (sesinetd license protocol) |
| **SDK** | SideFX sesinetd (bundled with Houdini) |
| **Auth** | License endpoint DNS (from Secrets Manager) — no client-side credentials |
| **Operations** | License checkout (houdini-21.0, karma-21.0, mantra-21.0), metered per-core-hour |
| **Network** | Direct-spawn: via ZeroTier to on-prem endpoint. Portal: via VPC endpoint (PrivateLink). |

### E7: EC2 Worker → Backblaze B2 (P2 → P5)

| Property | Value |
|---|---|
| **Transport** | HTTPS to `*.backblazeb2.com` |
| **SDK** | rclone (FUSE mount at `/mnt/renders`) |
| **Auth** | B2 key ID + app key from Secrets Manager (fetched at boot, written to `/etc/rclone/rclone.conf` mode 600) |
| **Operations** | Read inputs (`b2://aoin-test/inputs/`), write outputs (`b2://aoin-test/outputs/<job-id>_<job-name>/`) |

**Data contract:** S3-compatible API over HTTPS. B2 bucket paths map to POSIX paths via rclone FUSE.

### E8: EC2 Worker → ZeroTier Controller (P2 → P5)

| Property | Value |
|---|---|
| **Transport** | ZeroTier encrypted overlay (UDP) |
| **SDK** | `zerotier-cli` (C client) + ZeroTier REST API at `my.zerotier.com/api/` |
| **Auth** | ZeroTier network membership (node ID auto-generated). Auto-authorize via `houdini/zerotier-api-token` from Secrets Manager. |
| **Operations** | Join network `d3ecf5726d14ac76`, auto-authorize node, assign managed IP, connect to RCS at `10.147.18.89:4433` |

**Direct-spawn workers only.** Portal workers use Portal Gateway for RCS connectivity — no ZeroTier needed.

### E9: Operator → ZeroTier Controller (P6 → P5)

| Property | Value |
|---|---|
| **Transport** | HTTPS to `my.zerotier.com/api/v1/` |
| **SDK** | curl (in `launch_spot_worker.sh`, `terminate_spot_worker.sh`, `zerotier_authorize.sh`) |
| **Auth** | ZeroTier API token (from `houdini/zerotier-api-token` secret) |
| **Operations** | List members, authorize member, delete member on termination |

### E10: Operator → Deadline Cloud UBL (P6 → P4)

| Property | Value |
|---|---|
| **Transport** | HTTPS to `deadline.<region>.amazonaws.com` |
| **SDK** | AWS CLI `aws deadline` subcommands |
| **Auth** | AWS credentials (operator's profile) |
| **Operations** | `list-license-endpoints`, `create-license-endpoint`, `associate-persona-to-permission`, attach metered products (houdini-21.0, karma-21.0, mantra-21.0) |

**Script:** `aws/create_ubl_endpoint.sh` discovers the Portal VPC via CloudFormation, creates the endpoint, writes DNS to `houdini/license-endpoint-dns` in Secrets Manager.

### E11: Deadline Event Plugin → AWS APIs (P1 → P3)

*This edge is for the future AwsJobCostObserver plugin.*

| Property | Value |
|---|---|
| **Transport** | HTTPS to `ec2.<region>.amazonaws.com`, `pricing.<region>.amazonaws.com`, `athena.<region>.amazonaws.com` |
| **SDK** | boto3 (Python, running inside Deadline event plugin process) |
| **Auth** | RCS host IAM role (or explicit AWS credentials configured in plugin config) |
| **Required IAM** | `ec2:DescribeInstances`, `ec2:DescribeSpotPriceHistory`, `pricing:GetProducts`, `athena:StartQueryExecution`, `athena:GetQueryResults` |
| **Operations** | Instance lookup, spot price history, on-demand pricing, CUR 2.0 Athena queries |

**Critical constraint:** This edge runs synchronously inside the Deadline event pipeline. All calls must have timeouts (default 30s) and retries (default 2). See Error Handling in the component spec.

### E12: Deadline Event Plugin → Deadline Repository (P1 internal)

| Property | Value |
|---|---|
| **Transport** | In-process Python call (same host, same Deadline process) |
| **SDK** | `Deadline.Scripting.RepositoryUtils` |
| **Auth** | Implicit (plugin runs as Deadline service) |
| **Operations** | `GetJobTasks(jobId)`, `GetJobExtraInfo(jobId, index)`, `SetJobExtraInfo(jobId, index, value)`, job object properties (`job.Pool`, `job.Group`, `job.JobName`) |

**Constraint:** Must not mix with CLI `deadlinecommand` calls — the Python API returns objects, CLI returns text.

### E13: AWS Portal → AWS CloudFormation (P1/P3 internal)

| Property | Value |
|---|---|
| **Transport** | HTTPS (AWS Portal plugin → CloudFormation API) |
| **SDK** | Internal to AWS Portal (Thinkbox plugin calls AWS APIs) |
| **Auth** | AWS Portal IAM user configured in Deadline Monitor |
| **Operations** | Create/delete Portal stacks, manage VPC/subnets/SGs/NAT GW/EIPs |

**Resources created:** Parent stack (`stack*`), per-AZ child stacks, Gateway EC2, NAT GW, EIPs, S3 client bucket, VPC endpoints, placement groups.

---

## SDK / Interface Reference

### Deadline Scripting SDK (P1 internal, P1→P1)

The Deadline Python scripting layer is the primary interface for event plugins and
the Spot Event Plugin (SEP) configuration.

```python
from Deadline.Scripting import RepositoryUtils, JobUtils
```

| Method | Platform edge | Description |
|--------|---------------|-------------|
| `RepositoryUtils.GetJobTasks(jobId, True)` | E12 | Returns task objects with SlaveName, StartTime, EndTime |
| `RepositoryUtils.GetJobExtraInfo(jobId, index)` | E12 | Read ExtraInfo field by index (0-99, 1980-2000+) |
| `RepositoryUtils.SetJobExtraInfo(jobId, index, value)` | E12 | Write ExtraInfo field |
| `RepositoryUtils.GetEventPluginConfig("Spot")` | E12 | Read SEP config |
| `RepositoryUtils.AddOrUpdateEventPluginConfigSetting(...)` | E12 | Update SEP config |
| `job.Pool`, `job.Group`, `job.JobName`, `job.JobId` | E12 | Job object properties |
| `task.SlaveName`, `task.StartTime`, `task.EndTime` | E12 | Task object properties |
| `self.LogMessage()`, `self.LogWarning()`, `self.LogError()` | E12 | Plugin logging |

### AWS CLI / boto3 (cross-boundary P6→P3, P2→P3, P1→P3)

| Command | Edge | Used by |
|---------|------|---------|
| `aws ec2 run-instances` | E2 | `launch_spot_worker.sh`, `launch_build_instance.sh` |
| `aws ec2 describe-instances` | E2, E11 | `compute_job_cost.sh`, cost observer |
| `aws ec2 describe-spot-price-history` | E2, E11 | `compute_job_cost.sh`, cost observer |
| `aws ec2 terminate-instances` | E2 | `terminate_spot_worker.sh` |
| `aws ec2 describe-addresses` | E2 | `cleanup_all_infrastructure.sh` |
| `aws secretsmanager get-secret-value` | E5, E2 | Worker boot scripts, `create_ubl_endpoint.sh` |
| `aws secretsmanager put-secret-value` | E10 | `create_ubl_endpoint.sh` |
| `aws ssm send-command` / `get-command-invocation` | E2 | `launch_ready_spot_worker.sh`, `hotfix_instance.sh`, `terminate_spot_worker.sh` |
| `aws s3 cp` | E2 | `download_installers.sh`, `02_nvidia_drivers.sh`, `04_houdini.sh` |
| `aws pricing get-products` | E11 | Cost observer (on-demand fallback) |
| `aws athena start-query-execution` / `get-query-results` | E11 | Cost observer (Phase 2) |
| `aws cloudformation describe-stacks` | E2, E10 | `create_ubl_endpoint.sh`, `prepare_portal_region.sh` |
| `aws deadline list-license-endpoints` | E10 | `create_ubl_endpoint.sh`, `prepare_portal_region.sh` |
| `aws ec2 describe-images` | E2 | AMI validation |

### ZeroTier REST API (P2→P5, P6→P5)

| Endpoint | Edge | Method |
|----------|------|--------|
| `GET /api/v1/network/{network}/member` | E8, E9 | List members (find new nodes to authorize) |
| `POST /api/v1/network/{network}/member/{nodeId}` | E8 | Authorize member |
| `DELETE /api/v1/network/{network}/member/{nodeId}` | E9 | Remove member on termination |

**Auth header:** `Authorization: Bearer <token>` (token from `houdini/zerotier-api-token` secret).

### Backblaze B2 API (P2→P5)

Accessed via rclone, not direct API calls. rclone uses the S3-compatible B2 API
under the hood.

| Operation | Method |
|-----------|--------|
| List/read objects | `rclone ls`, `rclone copy` |
| Write render output | `rclone mount` (FUSE) or `rclone copyto` |
| Config | `/etc/rclone/rclone.conf` (written at boot from Secrets Manager) |

---

## Edge dependency matrix

This matrix shows which components depend on which external platforms. A ● means
the component calls across that platform boundary. This is the authoritative view
of "what breaks if a platform goes down."

| Component \ Platform | P1 RCS | P2 EC2 | P3 AWS Managed | P4 Deadline Cloud UBL | P5 ZeroTier | P5 B2 | P6 GitLab |
|---|---|---|---|---|---|---|---|
| `launch_spot_worker.sh` | ● (configure UBL) | ● (run-instances) | ● (SSM, EC2) | | ● (authorize node) | | |
| `launch_ready_spot_worker.sh` | ● (configure UBL, certs) | ● (run-instances) | ● (SSM, EC2, Secrets) | | ● (authorize node) | | |
| `launch_portal_worker_fleet.sh` | ● (Portal UI) | ● (Spot Fleet) | ● (CFN) | ● (UBL endpoint) | | | |
| `launch_build_instance.sh` | | ● (run-instances) | ● (EC2) | | | | |
| `create_ami.sh` | | ● (create-image) | ● (EC2) | | | | |
| `create_ubl_endpoint.sh` | | | ● (CFN, Secrets, SG) | ● (create endpoint) | | | |
| `prepare_portal_region.sh` | ● (Portal state) | ● (AMI check) | ● (CFN, Secrets, EC2) | ● (UBL status) | | | |
| `terminate_spot_worker.sh` | ● (removeWorker) | ● (terminate) | ● (SSM, EC2) | | ● (delete member) | | |
| `cleanup_all_infrastructure.sh` | | ● (describe/terminate) | ● (EC2, CFN, S3) | ● (delete endpoint) | | | |
| `compute_job_cost.sh` | ● (GetJobTasks) | ● (describe-instances) | ● (spot price, Athena) | | | | |
| `submit_test_render.sh` | ● (submit job) | | | | | | |
| `submit_b2_render.sh` | ● (submit job) | | | | | | |
| `cleanup_orphaned_sfrs.sh` | ● (SEP config) | ● (cancel SFRs) | ● (EC2) | | | | |
| `scan_gpu_capacity.sh` | | ● (spot capacity) | ● (EC2) | | | | |
| **Worker boot: 03_zerotier** | | | ● (Secrets) | | ● (join network) | | |
| **Worker boot: 04_houdini** | | | ● (Secrets) | ● (license DNS) | | | |
| **Worker boot: 04b_rclone** | | | ● (Secrets) | | | ● (mount B2) | |
| **Worker boot: 05_deadline** | ● (register worker) | | ● (S3 install) | | ● (RCS via ZT) | | |
| **Worker boot: 06_auto_group** | ● (SetGroups) | | | | ● (get ZT IP) | | |
| **AwsJobCostObserver** (future) | ● (RepositoryUtils) | ● (describe-instances) | ● (spot price, pricing, Athena) | | | | |
| **cost_reconcile.py** (future) | ● (SetExtraInfo) | | ● (Athena) | | | | |

---

## Auth and secrets cross-reference

How each platform boundary is authenticated:

| Edge | Auth mechanism | Credential source | Rotated how? |
|---|---|---|---|
| E1 (Op→RCS) | None (LAN trust) | N/A | N/A |
| E2 (Op→AWS) | AWS IAM user/role | `~/.aws/credentials` | Manual IAM rotation |
| E3 (Op→GitLab) | SSH ed25519 + PAT | `~/.ssh/` + config | Manual |
| E4 (RCS→Worker) | TLS certificates | Baked into AMI (`ca.crt` + RCS cert) | Manual AMI rebuild |
| E5 (Worker→Secrets) | IAM instance profile | `worker_secrets_policy.json` | IAM role change — no rotation needed |
| E6 (Worker→UBL) | Endpoint DNS (no client auth) | Secrets Manager at boot | `create_ubl_endpoint.sh` re-run |
| E7 (Worker→B2) | B2 key ID + app key | Secrets Manager at boot | Manual B2 rotation → update secret |
| E8 (Worker→ZT) | Network membership + API token | Secrets Manager at boot | Manual ZT token rotation |
| E9 (Op→ZT) | API token | Secrets Manager | Same as E8 |
| E10 (Op→UBL) | AWS IAM | Operator AWS credentials | Same as E2 |
| E11 (Plugin→AWS) | RCS host IAM role | Plugin config or host role | IAM role change |
| E12 (Plugin→Repo) | Implicit (in-process) | N/A | N/A |
| E13 (Portal→CFN) | AWS Portal IAM user | Deadline Monitor config | Manual |

---

## Failure domain map

What goes wrong when each platform boundary fails:

| Edge fails | Immediate symptom | Blast radius | Recovery |
|---|---|---|---|
| **E4** (RCS↔Worker) | Workers can't get tasks | All AWS rendering stops | Fix ZeroTier (E8) or Portal Gateway |
| **E5** (Worker→Secrets) | UBL, ZT, B2 all fail at boot | New workers can't start | Fix IAM role or Secrets Manager policy |
| **E6** (Worker→UBL) | Houdini won't launch | Workers boot but render fails | Re-run `create_ubl_endpoint.sh` |
| **E7** (Worker→B2) | Can't read inputs or write outputs | Renders fail or output lost | Check B2 keys in Secrets Manager |
| **E8** (Worker→ZT) | Worker can't reach RCS (direct-spawn) | Direct-spawn workers stop | Re-authorize node in ZT dashboard |
| **E11** (Plugin→AWS) | Cost computation skipped | No cost data (but jobs still complete) | Logged as warning; non-blocking |

---

## SDK version dependencies

| SDK | Version | Where used | Notes |
|---|---|---|---|
| Deadline Scripting | 10.4.2.3 | Event plugins, SEP config | `from Deadline.Scripting import RepositoryUtils` |
| AWS CLI | v2 | All `aws/` scripts, boot scripts | Required on RCS host (WSL) and operator workstation |
| boto3 | latest | AwsJobCostObserver (future) | Must be installed in Deadline's Python environment |
| rclone | latest | Worker boot (`04b_rclone_b2.sh`) | FUSE mount of B2 |
| ZeroTier CLI | 1.x | Worker boot (`03_zerotier.sh`), operator scripts | `zerotier-cli` |
| Python | 3.9+ | Boot scripts, compute_job_cost.sh, future plugins | AL2023 system Python |
| Houdini | 21.0 | Worker rendering | `/opt/hfs21.0/` |

---

## Glossary

| Term | Meaning |
|---|---|
| **RCS** | Repository Connection Server — the Deadline service that manages the job queue and repository |
| **SEP** | Spot Event Plugin — Deadline's built-in auto-scaling plugin that creates Spot Fleet Requests based on queue depth |
| **SFR** | Spot Fleet Request — AWS construct for requesting multiple spot instances |
| **UBL** | Usage-Based Licensing — SideFX metered licensing model (per-core-hour) |
| **ExtraInfo** | Deadline's generic key-value metadata on jobs (indices 0-99, 1980-2000+) |
| **CUR 2.0** | Cost and Usage Report 2.0 — AWS billing data export with resource-level granularity |
| **Portal** | Deadline AWS Portal — Thinkbox's managed infrastructure feature for bursting to AWS |
| **Direct-spawn** | Our custom CLI scripts that launch spot workers directly (vs Portal-managed) |
| **DeadlineTrackedAWSResource** | Tag applied to all EC2 resources for the Resource Tracker to find |

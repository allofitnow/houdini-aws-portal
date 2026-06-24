# AwsJobCostObserver — Design Spec

## Problem statement

Today, per-job AWS render cost can only be computed **after the fact, manually**, by
running `compute_job_cost.sh <job_id>` from the workstation. Nobody remembers to do this.
The result is:

- No one knows what a render actually cost until someone asks
- Spot budget overruns (e.g., a stuck job burning $2/hr for 3 days) are invisible
- CUR 2.0 actuals (`--actuals`) are never reconciled against the spot-price estimate
- There is no historical record — each run is ephemeral
- Producers/artists have no visibility into whether their scenes are expensive

## Solution: Deadline Event Plugin

**AwsJobCostObserver** is a Deadline 10 Event Plugin that fires automatically when a job
completes (or fails), computes its estimated AWS cost, stores it in the job's metadata,
and optionally reconciles against CUR 2.0 actuals the next day.

### Two-phase cost model (already proven in compute_job_cost.sh)

| Phase | When | Data source | Accuracy | Latency |
|-------|------|-------------|----------|---------|
| **Phase 1 — Estimate** | Job completes (immediate) | `DescribeSpotPriceHistory` (spot) or Price List API (on-demand) + instance runtime | ±5-10% | 0 min |
| **Phase 2 — Actual** | Next day (scheduled) | CUR 2.0 via Athena, queried by `resource_id` | Exact | 8-24h |

This design reuses the logic from `compute_job_cost.sh` but wraps it in an automated
event-driven pipeline instead of manual CLI invocation.

---

## Environment context

The Deadline RCS (Repository Connection Server) runs on a **Windows host**
(`192.168.30.231`) accessed via WSL. Key paths:

| Component | Path |
|-----------|------|
| Deadline client install | `/mnt/c/Program Files/Thinkbox/Deadline10/` |
| **Deadline Repository** | **`/mnt/c/DeadlineRepository10/`** |
| RCS cert directory | `/mnt/c/Users/aoin/.deadline/certs/` |
| `deadlinecommand` (WSL) | `/mnt/c/Program Files/Thinkbox/Deadline10/bin/deadlinecommand.exe` |

**Event plugins are installed in the Repository directory**, not the client install
directory. The existing AWSPortal plugin confirms this:
`/mnt/c/DeadlineRepository10/events/AWSPortal/` (AWSPortal.py, AWSPortalUtils.py, AWSPortal.param).

> **`REPO_ROOT`** in this document refers to `/mnt/c/DeadlineRepository10/` (WSL path)
> or `C:\DeadlineRepository10\` (native Windows path).

> **`DL_BIN`** refers to `/mnt/c/Program Files/Thinkbox/Deadline10/bin/deadlinecommand.exe`.

---

## Architecture

```
 Deadline Job Completes or Fails
        │
        ▼
 ┌──────────────────────────┐
 │  OnJobFinished event     │     Deadline Event Plugin (this component)
 │  (AwsJobCostObserver)    │
 └──────────┬───────────────┘
            │
            ├─► 1. Detect whether this is an AWS job
            │      (pool, group, OR ExtraInfo2000 — see AWS job detection)
            │
            ├─► 2. Query Deadline for job metadata
            │      (start time, end time, workers, plugin, pool, submitter)
            │
            ├─► 3. Resolve worker hostnames → EC2 instance IDs
            │      (describe-instances by private DNS)
            │
            ├─► 4. Get instance type + AZ for EACH instance
            │      (multi-instance aware — see cost computation)
            │
            ├─► 5. For EACH instance, query spot price (or on-demand fallback)
            │      for that instance's specific time window
            │
            ├─► 6. Compute per-instance cost, sum for total
            │      render_cost = Σ (price_i × render_hours_i)
            │
            ├─► 7. Write Phase 1 estimate to Deadline ExtraInfo fields
            │      ExtraInfo1980 = {"phase":"estimate","cost":"12.34", ...}
            │      ExtraInfo1981 = "estimated:$12.34 (g6e.4xlarge, 3.2h spot)"
            │
            ├─► 8. Record job_id + instance_ids + timing to a local JSONL log
            │      {REPO_ROOT}/reports/cost_observer.jsonl
            │
            ├─► 9. Write per-job CSV report
            │      {REPO_ROOT}/reports/job_cost_reports/<job_id>_<name>_<ts>.csv
            │
            └─► 10. Alert if over threshold
                   if render_cost > $CostAlertThreshold: send_alert(job, render_cost)
                        │
                        ▼
              Next-day reconciliation cron
                        │
                   ┌────┴────┐
                   │ Athena  │  Queries CUR 2.0 by resource_id
                   │ query   │  for each instance in the log
                   └────┬────┘
                        │
                        ▼
                   Update Deadline ExtraInfo fields
                   with Phase 2 actuals
                   Flag variance > 10%
                   Update CSVs with actuals
```

---

## Component breakdown

### A. Deadline Event Plugin (`AwsJobCostObserver.py`)

**Location:** `{REPO_ROOT}/events/AwsJobCostObserver/` — i.e., `/mnt/c/DeadlineRepository10/events/AwsJobCostObserver/`

> Event plugins are installed under the **Repository** directory (confirmed by the
> existing AWSPortal plugin at `{REPO_ROOT}/events/AWSPortal/`). This is NOT the
> same as the client install directory at `/mnt/c/Program Files/Thinkbox/Deadline10/`.
> `/opt/Thinkbox/Deadline10/` is the **worker AMI** path on AL2023 and does not exist
> on the RCS host.

**Event:** `OnJobFinished` — fires when any job transitions to a terminal state.

Deadline 10's `OnJobFinished` event fires for **both `Completed` and `Failed` jobs**.
This is critical because failed jobs that burned compute (e.g., a job stuck rendering
for 3 days then failing) are exactly the ones we need to cost. If the plugin is also
needed for jobs that are *cancelled* (not completed or failed), `OnJobPended` can be
added as a secondary event in a future iteration.

**AWS job detection (in-plugin, not config-based):**

The observer must fire for ALL jobs and decide in-code whether each is an AWS job.
This replaces the unreliable `LimitToGroups`/`LimitToPools` config approach because:

1. `awsportal` is a **pool** name, not a group — putting it in `LimitToGroups` does nothing.
2. Portal test jobs (`submit_test_render.sh`) submit with **empty pool and empty group**.
3. B2 render jobs (`submit_b2_render.sh`) submit to `Pool=none` but ARE AWS jobs.
4. The `none` pool is used by both on-prem jobs AND some AWS jobs.

The plugin uses the same dual detection as `compute_job_cost.sh` (line 89):

```python
def is_aws_job(job):
    # Method 1: Pool/group name check
    AWS_POOLS = {"aws-spot", "aws-spot-east", "awsportal", "awsportal-east"}
    AWS_GROUPS = {"aws-spot", "aws-spot-east"}
    if job.Pool in AWS_POOLS:
        return True, ("portal" if job.Pool.startswith("awsportal") else "spot")
    if job.Group in AWS_GROUPS:
        return True, "spot"
    # Method 2: ExtraInfo2000 Portal flag (used by compute_job_cost.sh)
    extra = deadline.GetJobSetting(job.ID, "ExtraInfo2000")
    if extra and "Portal" in extra:
        return True, "portal"
    # Method 3: Worker hostname pattern (ip-10-*.ec2.internal, ip-10-128-* etc.)
    # If any worker that rendered this job has an EC2-style hostname, it's AWS
    return False, None
```

**Config (`eventplugine.config`):**

```json
{
  "Version": 1,
  "Name": "AwsJobCostObserver",
  "Enabled": true,
  "Event": "OnJobFinished",
  "LimitToGroups": "",
  "LimitToPools": "",
  "Config": {
    "AWSRegion": "us-west-2",
    "SpotRegions": "us-west-2,us-east-1",
    "CurDatabase": "deadline_cost",
    "CurTable": "cur_2_0",
    "AthenaOutputBucket": "s3://deadline-cost-athena-results/",
    "CostAlertThreshold": "50.00",
    "ReconciliationEnabled": true,
    "ReportsDir": "/mnt/c/DeadlineRepository10/reports",
    "JobCostReportsDir": "/mnt/c/DeadlineRepository10/reports/job_cost_reports"
  }
}
```

`LimitToGroups` and `LimitToPools` are both **empty** — the plugin fires for every
job and does in-code AWS detection (see above). This ensures Portal jobs with empty
pool/group fields are not missed.

**Plugin logic (Python, runs on the RCS host):**

```python
# Pseudocode — actual implementation in AwsJobCostObserver.py

def OnJobFinished(job, startTime, endTime):
    # 1. Detect whether this is an AWS job
    is_aws, job_type = is_aws_job(job)
    if not is_aws:
        return

    # 2. Get workers that rendered this job
    tasks = deadline.GetJobTasks(job.ID)
    worker_hostnames = {t.SlaveName for t in tasks}
    instance_ids = resolve_to_instance_ids(worker_hostnames, region)

    # 3. Get metadata for EACH instance (multi-instance aware)
    instance_infos = {}
    for iid in instance_ids:
        info = get_instance_info(iid, region)  # type, az, launch_time, lifecycle
        instance_infos[iid] = info

    # 4. Compute cost per instance, then sum
    total_render_cost = 0.0
    total_instance_cost = 0.0
    per_instance_details = []

    for iid, info in instance_infos.items():
        render_hours_i = compute_render_hours(iid, startTime, endTime)

        if info.lifecycle == "spot":
            price_i = get_avg_spot_price(info.type, info.az, startTime, endTime, info.region)
        else:
            # On-demand fallback for Portal / non-spot instances
            price_i = get_on_demand_price(info.type, info.region)

        render_cost_i = render_hours_i * price_i
        instance_cost_i = compute_instance_cost(info.launch_time, endTime, price_i)

        total_render_cost += render_cost_i
        total_instance_cost += instance_cost_i
        per_instance_details.append({
            "instance_id": iid,
            "type": info.type,
            "az": info.az,
            "lifecycle": info.lifecycle,
            "render_hours": round(render_hours_i, 2),
            "price_per_hr": round(price_i, 4),
            "render_cost": round(render_cost_i, 2),
            "instance_cost": round(instance_cost_i, 2),
        })

    # 5. Write to Deadline ExtraInfo
    cost_json = {
        "phase": "estimate",
        "job_type": job_type,              # "spot" or "portal"
        "render_cost": round(total_render_cost, 2),
        "instance_cost": round(total_instance_cost, 2),
        "instances": per_instance_details,  # per-instance breakdown
        "computed_at": datetime.utcnow().isoformat() + "Z"
    }
    deadline.SetJobSetting(job.ID, "ExtraInfo1980", json.dumps(cost_json))
    deadline.SetJobSetting(job.ID, "ExtraInfo1981",
        f"estimated:${total_render_cost:.2f} ({len(instance_ids)} inst, {render_hours_total:.1f}h)")

    # 6. Log to JSONL for reconciliation
    append_cost_log(job.ID, cost_json)

    # 7. Write per-job CSV report
    write_job_cost_csv(job, cost_json)

    # 8. Alert if over threshold
    if total_render_cost > float(config.CostAlertThreshold):
        send_alert(job, total_render_cost)
```

### B. AWS job detection logic

**Problem:** Deadline jobs don't reliably carry a single field that says "this is an
AWS job." Different submission paths use different conventions:

| Submission path | Pool | Group | ExtraInfo2000 | Is AWS? |
|-----------------|------|-------|---------------|---------|
| `submit_test_render.sh` (Portal test) | *(empty)* | *(empty)* | Set by Portal | ✅ Yes |
| `submit_b2_render.sh` (B2 spot) | `none` | `aws-spot-east` | *(not set)* | ✅ Yes |
| Direct-spawn spot worker | `aws-spot` | `aws-spot` | *(not set)* | ✅ Yes |
| Portal fleet worker | `awsportal` | *(varies)* | Contains "Portal" | ✅ Yes |
| On-prem local worker | `none` | *(varies)* | *(not set)* | ❌ No |

**Detection order (same as `compute_job_cost.sh`):**
1. Pool in `{"aws-spot", "aws-spot-east", "awsportal", "awsportal-east"}` → AWS
2. Group in `{"aws-spot", "aws-spot-east"}` → AWS
3. `ExtraInfo2000` contains "Portal" → AWS (Portal-managed)
4. Worker hostname matches EC2 pattern (`ip-10-*`, `.ec2.internal`) → AWS
5. Otherwise → not AWS, skip

### C. Instance-to-job mapping & cost computation

**Multi-instance aware:**

A single Deadline job often spans **multiple EC2 instances** (e.g., 240 frames
distributed across 4 spot workers). Each instance may be a **different type** in a
**different AZ** with a **different spot price**.

```
Job 65a3f1b2 (240 frames, 3.2h total):
  ├── i-0abc123 (g6e.4xlarge, us-west-2a, spot, 0.72/hr, 2.1h) → $1.51
  ├── i-0def456 (g6e.4xlarge, us-west-2b, spot, 0.68/hr, 1.1h) → $0.75
  ├── i-0ghi789 (g6.xlarge,  us-west-2a, spot, 0.35/hr, 0.5h) → $0.18
  └── i-0jkl012 (g6e.4xlarge, us-west-2a, spot, 0.72/hr, 1.0h) → $0.72
                                                       Total render_cost → $3.16
```

Each instance's cost is computed independently using its own type, AZ, lifecycle
(spot vs on-demand), and time window. The job's total is the sum.

### D. Pricing model (spot + on-demand fallback)

The plugin handles both spot and on-demand (Portal) instances:

| Instance lifecycle | Pricing source | Method |
|--------------------|----------------|--------|
| **Spot** (direct-spawn workers) | `DescribeSpotPriceHistory` | Average spot price during the instance's render window |
| **On-demand** (Portal-managed, or spot with no history) | AWS Price List API (`pricing/GetProducts`) | Public on-demand rate for the instance type + region |

**Spot fallback chain:** If `DescribeSpotPriceHistory` returns no data for the
window (instance was a new type, or the window is outside the 90-day history), the
plugin falls back to on-demand price from the Price List API and flags the estimate
with `"pricing_source": "on_demand_fallback"` in the JSON.

### E. Deadline ExtraInfo field map

Deadline provides 100 user-defined ExtraInfo fields (0-99) and 100 custom
ExtraInfo fields (1980-2000+). The AwsJobCostObserver uses fields in the custom
range to avoid collision with user-defined fields.

| Field | Owner | Purpose |
|------|-------|---------|
| `ExtraInfo2000` | **AWS Portal** (existing) | Portal metadata (instance ID, fleet info) — read by `compute_job_cost.sh` for Portal detection. **Do not modify.** |
| `ExtraInfo1980` | **AwsJobCostObserver** (this spec) | Phase 1 cost estimate JSON (machine-readable) |
| `ExtraInfo1981` | **AwsJobCostObserver** (this spec) | Human-readable cost summary string |
| `ExtraInfo1982` | **AwsJobCostObserver** (this spec) | Phase 2 actual cost JSON (after reconciliation) |

**Reservation rule:** Before implementation, run this command on the RCS host to
verify no other plugin uses fields 1980-1982:

```bash
DL_BIN="/mnt/c/Program Files/Thinkbox/Deadline10/bin/deadlinecommand.exe"
for i in $(seq 1980 1982); do
    echo "ExtraInfo${i}:"
    "$DL_BIN" -GetEventPluginConfig 2>/dev/null | grep -i "ExtraInfo${i}" || echo "  (not referenced)"
done
```

### F. Deadline Monitor integration

The ExtraInfo fields surface in Deadline Monitor's job list columns:

| ExtraInfo field | Example value | Display |
|-----------------|---------------|---------|
| `ExtraInfo1980` | `{"phase":"estimate","render_cost":12.34,...}` | JSON (machine-readable) |
| `ExtraInfo1981` | `estimated:$12.34 (g6e.4xlarge, 3.2h spot)` | Human-readable summary |
| `ExtraInfo1982` | `{"phase":"reconciled","cost":11.87,...}` | Phase 2 actuals (next day) |

Deadline admins can add custom columns to the Monitor's job list view showing
`ExtraInfo1981` so every job shows its cost at a glance.

### G. Cost alert thresholds

Alerts are sent via Deadline's built-in notification system (email / Slack webhook).

| Condition | Action |
|-----------|--------|
| Single job cost > `$CostAlertThreshold` (default $50) | Email job submitter + admin |
| Daily aggregate AWS spend > $500 | Email admin (computed from JSONL log) |
| Estimate vs actual variance > 10% | Log warning in reconciliation report |

### H. Per-job CSV reports

Every job that completes also writes an individual CSV cost report to a
`job_cost_reports/` subfolder. This gives a permanent, portable, per-job cost
record that can be opened in Excel, shared with producers, or ingested by
downstream billing systems.

**Location:** `{REPO_ROOT}/reports/job_cost_reports/` — i.e., `/mnt/c/DeadlineRepository10/reports/job_cost_reports/`

**Filename:** `<job_id>_<job_name_sanitized>_<YYYYMMDD-HHMMSS>.csv`

Example: `65a3f1b2_portal_ami_test_render_20260624-143052.csv`

**CSV schema (22 columns):**

| # | Column | Type | Example | Description |
|---|--------|------|---------|-------------|
| 1 | `job_id` | string | `65a3f1b2` | Deadline job ID |
| 2 | `job_name` | string | `Portal_AMI_Test_Render` | Job name from Deadline |
| 3 | `submitted_by` | string | `howong` | Deadline job submitter username |
| 4 | `status` | string | `Completed` | Final job status (Completed / Failed) |
| 4 | `plugin` | string | `Houdini` | Deadline plugin |
| 5 | `pool` | string | `awsportal` | Deadline pool |
| 6 | `group` | string | `aws-spot-east` | Deadline group |
| 7 | `is_portal` | bool | `true` | Whether this was a Portal-managed job |
| 8 | `frames` | string | `1-240` | Frame range |
| 9 | `render_start` | ISO 8601 | `2026-06-24T14:00:00Z` | Job render start (UTC) |
| 10 | `render_end` | ISO 8601 | `2026-06-24T17:12:34Z` | Job render end (UTC) |
| 11 | `render_hours` | float | `3.21` | Total render duration in hours |
| 12 | `instance_ids` | string (semicolon-delimited) | `i-0abc123;i-0def456` | All EC2 instances that rendered this job |
| 13 | `instance_types` | string (semicolon-delimited) | `g6e.4xlarge;g6.xlarge` | Instance types (aligned with instance_ids by position) |
| 14 | `az` | string (semicolon-delimited) | `us-west-2a;us-west-2b` | AZs (aligned with instance_ids by position) |
| 15 | `phase` | string | `estimate` | `estimate` (Phase 1) or `reconciled` (Phase 2 after reconciliation) |
| 16 | `pricing_source` | string | `spot` | `spot`, `on_demand`, or `on_demand_fallback` |
| 17 | `avg_spot_price_hr` | float | `0.7234` | Average spot price during job window ($/hr) |
| 18 | `render_cost` | float | `2.32` | **Authoritative job cost.** Compute cost for the render duration only ($) |
| 18 | `instance_cost` | float | `2.89` | Instance cost from launch to termination ($) |
| 19 | `actual_cost` | float | *(empty)* | CUR 2.0 actual cost (empty until Phase 2 reconciliation) |
| 20 | `variance_pct` | float | *(empty)* | `(actual - estimate) / actual × 100` (empty until Phase 2) |
| 21 | `currency` | string | `USD` | Always USD |
| 22 | `computed_at` | ISO 8601 | `2026-06-24T17:12:35Z` | When this report was generated |

**Cost definitions (authoritative):**

- **`render_cost`** is the **authoritative job cost**. It represents compute cost for
  the render window only (task start → task end), not instance lifetime. This is what
  alerts, reconciliation, and reporting use.
- **`instance_cost`** is supplementary. It covers launch → termination (includes boot
  time, health-check delay, deregistration). Useful for TCO analysis but not per-job billing.

**Example CSV file:**

```csv
job_id,job_name,submitted_by,status,plugin,pool,group,is_portal,frames,render_start,render_end,render_hours,instance_ids,instance_types,az,phase,pricing_source,avg_spot_price_hr,render_cost,instance_cost,actual_cost,variance_pct,currency,computed_at
65a3f1b2,Portal_AMI_Test_Render,howong,Completed,Houdini,awsportal,,true,1-240,2026-06-24T14:00:00Z,2026-06-24T17:12:34Z,3.21,i-0abc123;i-0def456,g6e.4xlarge;g6.xlarge,us-west-2a;us-west-2b,estimate,spot,0.7234,2.32,2.89,,,USD,2026-06-24T17:12:35Z
```

**Behavior:**

- **Phase 1 (estimate):** Written immediately on job completion. `actual_cost` and
  `variance_pct` columns are empty. `phase` = `estimate`.
- **Phase 2 (actual):** The reconciliation cron updates the same file in-place,
  filling in `actual_cost`, `variance_pct`, and changing `phase` from `estimate`
  to `reconciled`.
- **Job name sanitization:** Job names are stripped of filesystem-unsafe characters
  (`/ \ : * ? " < > |`) and truncated to 50 chars to form the filename.
- **Deduplication:** The `<job_id>` appears as the leading segment of the filename
  and is guaranteed unique. If a CSV already exists for a job_id (glob pattern
  `<job_id>_*`), the Phase 2 update overwrites it rather than creating a duplicate.
- **Permissions:** Files are owned by the Deadline service account with mode `644`
  (Windows: full control for SYSTEM/Administrators, read for Users).
- **Retention:** CSV files are never auto-deleted. The `cost_report.py` weekly
  generator (Phase 3) reads all CSVs in this folder for aggregate reporting.

---

## Relationship to existing code

| Existing artifact | Relationship |
|---|---|
| `aws/compute_job_cost.sh` | **Direct reuse** — Phase 1/2 logic is extracted into Python functions shared with the plugin. The shell script remains as a manual CLI fallback. |
| `docs/research/aws-billing-apis-research.md` | **Informs** the CUR 2.0 + Athena reconciliation design. Already evaluated all billing APIs. |
| `aws/AWS-RESEARCH-NETWORKING-COSTS.md` | **Informs** the cost model — NAT GW, EIP, VPC endpoint costs are included in the total cost of ownership but NOT attributed per-job (they're infrastructure, not per-render). |
| AWS Resource Tracker wiki | **Complementary** — Resource Tracker finds leaks (infrastructure). JobCostObserver tracks per-job spend (compute). |

### What JobCostObserver does NOT track per-job

These are infrastructure costs, not per-render:

- NAT Gateway hourly ($0.045/hr) — shared across all Portal jobs
- VPC Interface endpoint ($0.01/hr/AZ) — shared
- UBL licensing fees — per-job but billed separately via Deadline Cloud
- EBS volumes — attached to instances, not per-job
- Public IPv4 ($0.005/hr) — per-instance, not per-job

Per-job cost = **spot instance compute cost only**. Infrastructure costs are tracked
separately by the Resource Tracker.

---

## Prerequisites

### AWS-side setup (one-time)

1. **Enable CUR 2.0** (Billing → Cost & Usage Report)
   - Hourly granularity, Parquet format
   - Resource-level data: on
   - S3 bucket: `s3://deadline-cost-reports/`
   - Athena integration: enabled (auto-creates table `cur_2_0` in Glue)

2. **Set up Athena** workgroup + output bucket
   - Workgroup: `deadline-cost`
   - Output: `s3://deadline-cost-athena-results/`

3. **Enable cost allocation tags** (Billing → Cost Allocation Tags)
   - Activate tag key: `project` (so `EC2:project` appears in CUR)

4. **IAM permissions** for the RCS host role:
   ```
   ce:GetCostAndUsage
   athena:StartQueryExecution, GetQueryExecution, GetQueryResults
   ec2:DescribeInstances, DescribeSpotPriceHistory
   s3:GetObject (for CUR bucket)
   pricing:GetProducts
   ```

### Deadline-side setup

1. Install plugin to `{REPO_ROOT}/events/AwsJobCostObserver/` (i.e., `/mnt/c/DeadlineRepository10/events/AwsJobCostObserver/`)
2. Configure `eventplugine.config` with region, CUR table, thresholds, report paths
3. Restart Deadline Pulse
4. Verify ExtraInfo 1980-1982 are not used by any other plugin (see field map)
5. Verify: submit a test render → check `ExtraInfo1980` appears

---

## Open questions

| # | Question | Default if unresolved |
|---|----------|-----------------------|
| 1 | Should cost data persist after jobs are deleted from Deadline? | Yes — JSONL log + CSVs are the permanent record |
| 2 | How to handle multi-region jobs (us-west-2 + us-east-1 failover)? | Query spot price per-instance-region, not job-level |
| 3 | Should artists see cost in Deadline Monitor, or admin-only? | Admin-only initially; artist visibility is Phase 2 |
| 4 | CUR Athena query timeout — what if CUR data is delayed >48h? | Skip reconciliation, retry next day, alert after 72h |
| 5 | If `pricing_source` is mixed (some spot, some on-demand) across instances in one job? | Per-instance: each instance uses its own lifecycle-appropriate price. `pricing_source` column stores the majority source; JSON stores per-instance detail. |
| 6 | DeadSlave events — should cost be computed when a worker crashes mid-render? | Phase 1: no. The job's OnJobFinished will fire when the job itself finishes regardless of individual worker outcomes. |

---

## Implementation phases

### Phase 1 — Event Plugin (estimate-only)
- Implement `AwsJobCostObserver.py` Deadline Event Plugin
- OnJobFinished → compute Phase 1 spot/on-demand estimate
- Multi-instance aware cost computation
- Write to ExtraInfo1980/1981
- Log to JSONL
- Write per-job CSV to `job_cost_reports/`
- Basic cost threshold alert
- **Deliverable:** Plugin file + config + install instructions

### Phase 2 — CUR Reconciliation
- Implement `cost_reconcile.py` daily cron
- Athena query per job for actuals
- **Allocation algorithm:** proportional by render_hours (see reconciliation below)
- Update ExtraInfo1982 with Phase 2 actuals
- Update CSV files in `job_cost_reports/` with actual_cost + variance_pct
- Variance flagging
- **Deliverable:** Cron script + Athena setup runbook

### Phase 3 — Dashboard (optional)
- Generate weekly cost report from CSV files in `job_cost_reports/`
- Per-show / per-artist cost breakdown (uses `submitted_by` column)
- Trend analysis (cost per frame over time)
- Export to CSV / spreadsheet
- **Deliverable:** Report generation script

---

## Reconciliation allocation algorithm (Phase 2)

When multiple jobs share the same instance in the same billing hour, costs must be
allocated proportionally. The algorithm:

1. Query CUR 2.0 for the instance's total cost during the job window
2. Sum the render_hours of all jobs on that instance during that hour
3. Allocate: `job_cost = hourly_cost × (job_render_hours / total_render_hours_in_hour)`
4. Sum allocated costs across all hours the instance was alive

**Why render_hours (not frames or tasks):** render hours directly correlate to compute
consumed. A job rendering 10 frames in 2 hours consumes the same GPU as a job rendering
200 frames in 2 hours on the same GPU type.

**Example:**

```
Instance i-0abc123, us-west-2a, g6e.4xlarge, hour 14:00-15:00 UTC:
  CUR cost: $0.72 (1 hour spot)
  Jobs active in this hour:
    Job A: 1.2 render hours in this hour
    Job B: 0.8 render hours in this hour
    Total: 2.0 render hours
  Allocation:
    Job A: $0.72 × (1.2 / 2.0) = $0.43
    Job B: $0.72 × (0.8 / 2.0) = $0.29
```

**Edge cases:**

- **Instance idle (no jobs):** Idle time cost is NOT attributed to any job. It's
  infrastructure waste, tracked by the Resource Tracker.
- **Single job on instance:** 100% allocation, no splitting.
- **Job spans multiple hours:** Sum the per-hour allocations.
- **Instances of different types:** Each instance is allocated independently.

---

## File layout (to be implemented)

```
{REPO_ROOT}/events/AwsJobCostObserver/        # i.e., /mnt/c/DeadlineRepository10/events/AwsJobCostObserver/
    AwsJobCostObserver.py      # Event plugin (OnJobFinished)
    eventplugine.config        # Plugin config (JSON)
    cost_utils.py              # Shared cost computation logic (multi-instance, spot+on-demand)
    README.md                  # Install + config instructions

{REPO_ROOT}/reports/                           # i.e., /mnt/c/DeadlineRepository10/reports/
    cost_observer.jsonl        # Append-only cost log (JSONL)
    job_cost_reports/          # Per-job CSV cost reports (this spec)
    cost_reconcile.py          # Daily reconciliation cron
    cost_report.py             # Weekly report generator (Phase 3)
```

---

## Exit criteria (Phase 1)

- [ ] Submit a render job to an AWS pool → job completes → `ExtraInfo1980` populated
- [ ] `ExtraInfo1981` shows human-readable cost summary in Deadline Monitor
- [ ] JSONL log entry written with correct instance IDs and timing
- [ ] Per-job CSV written to `job_cost_reports/<job_id>_<name>_<timestamp>.csv`
- [ ] CSV contains all 22 columns with correct values (spot price, render hours, costs)
- [ ] Multi-instance job: each instance's cost computed independently (verify with a
      job that spans 2+ instances of different types)
- [ ] Portal (on-demand) job: cost computed via Price List API, not $0
- [ ] Failed job: cost computed and logged (verify OnJobFinished fires for Failed)
- [ ] Cost within ±10% of `compute_job_cost.sh` for the same job
- [ ] Non-AWS jobs (no AWS pool, group, ExtraInfo2000, or EC2 hostname) are skipped
- [ ] Cost threshold alert fires when job exceeds `$CostAlertThreshold`

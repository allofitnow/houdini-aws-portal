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
| **Phase 1 — Estimate** | Job completes (immediate) | `DescribeSpotPriceHistory` (spot) or Price List API (on-demand) + per-instance task durations | ±5-10% | 0 min |
| **Phase 2 — Reconciled** | Next day (scheduled) | CUR 2.0 via Athena, queried by `resource_id` | Exact | 8-24h |

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
            │      → non-AWS jobs: return immediately (no cost computation)
            │
            ├─► 2. Query Deadline for job metadata + task list
            │      (start/end, plugin, pool, submitter, task-level slave assignments)
            │
            ├─► 3. Resolve worker hostnames → EC2 instance IDs
            │      (describe-instances by private DNS name)
            │
            ├─► 4. Get instance type + AZ + lifecycle for EACH instance
            │      (describe-instances, multi-instance aware)
            │
            ├─► 5. Compute per-instance render_hours from TASK data
            │      (sum task durations per instance, NOT job-level window)
            │
            ├─► 6. For EACH instance, query spot price (or on-demand fallback)
            │      for that instance's specific type, AZ, and time window
            │
            ├─► 7. Compute per-instance cost, sum for total
            │      render_cost = Σ (price_i × render_hours_i)
            │
            ├─► 8. Write Phase 1 estimate to Deadline ExtraInfo fields
            │      ExtraInfo1980 = {"phase":"estimate","cost":"12.34", ...}
            │      ExtraInfo1981 = "estimated:$12.34 (4 inst, 3.2h spot)"
            │
            ├─► 9. Record job_id + instance_ids + timing to a local JSONL log
            │      {REPO_ROOT}/reports/cost_observer.jsonl
            │
            ├─► 10. Write per-job CSV report
            │      {REPO_ROOT}/reports/job_cost_reports/<job_id>_<name>_<ts>.csv
            │
            └─► 11. Alert if over threshold
                   if render_cost > $CostAlertThreshold: send_alert(job, render_cost)

        All steps wrapped in try/except with timeouts (see Error Handling).
        Plugin never blocks the Deadline event pipeline.

                        │
                        ▼
              Next-day reconciliation cron
                        │
                   ┌────┴────┐
                   │ Athena  │  Queries CUR 2.0 by resource_id
                   │ query   │  for each instance in the log
                   └────┬────┘
                        │
                   Scan JSONL for overlapping jobs on same instances
                        │
                        ▼
                   Allocate actual cost proportionally by render_hours
                   Update Deadline ExtraInfo1982 with actuals
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

**Deadline Python Event Plugin API:**

The existing `cleanup_orphaned_sfrs.sh` and `Instance-Allocation.md` wiki both import
from `Deadline.Scripting`. The plugin uses:

```python
from Deadline.Scripting import RepositoryUtils, JobUtils
```

Key API calls (exact method names verified during Prerequisite P4):

| Operation | API |
|-----------|-----|
| Get job tasks (with slave assignments) | `RepositoryUtils.GetJobTasks(jobId, True)` |
| Get job ExtraInfo by index | `RepositoryUtils.GetJobExtraInfo(jobId, index)` |
| Set job ExtraInfo by index | `RepositoryUtils.SetJobExtraInfo(jobId, index, value)` |
| Get job property (Pool, Group, etc.) | `job.Pool`, `job.Group`, `job.JobName`, `job.JobId` |
| Get task slave name | `task.SlaveName`, `task.StartTime`, `task.EndTime` |
| Log to Deadline | `self.LogMessage("...")` / `self.LogWarning("...")` |

> **Important:** The CLI `dl -GetJobTasks "$JOB_ID"` (used by `compute_job_cost.sh`)
> returns text output. The Python plugin API returns objects. Do not mix them.

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
    "JobCostReportsDir": "/mnt/c/DeadlineRepository10/reports/job_cost_reports",
    "ApiTimeoutSeconds": "30",
    "MaxRetryAttempts": "2"
  }
}
```

`LimitToGroups` and `LimitToPools` are both **empty** — the plugin fires for every
job and does in-code AWS detection (see below). This ensures Portal jobs with empty
pool/group fields are not missed.

`ApiTimeoutSeconds` (default 30) and `MaxRetryAttempts` (default 2) control AWS API
call behavior. If exceeded, the plugin logs an error and continues without blocking
the Deadline event pipeline (see Error Handling section).

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
    """
    Returns (bool, job_type) where job_type is "spot" or "portal".
    is_portal (for CSV) is derived: is_portal = (job_type == "portal").
    """
    AWS_POOLS = {"aws-spot", "aws-spot-east", "awsportal", "awsportal-east"}
    AWS_GROUPS = {"aws-spot", "aws-spot-east"}

    # Method 1: Pool name check
    if job.Pool in AWS_POOLS:
        return True, ("portal" if job.Pool.startswith("awsportal") else "spot")

    # Method 2: Group name check
    if job.Group in AWS_GROUPS:
        return True, "spot"

    # Method 3: ExtraInfo2000 Portal flag (used by compute_job_cost.sh line 87)
    extra = RepositoryUtils.GetJobExtraInfo(job.JobId, 2000)
    if extra and "Portal" in extra:
        return True, "portal"

    # Method 4: Worker hostname pattern — if any worker has an EC2-style
    # private DNS name (ip-10-*.compute.internal, ip-10-*.ec2.internal),
    # the job ran on AWS.
    tasks = RepositoryUtils.GetJobTasks(job.JobId, True)
    for task in tasks:
        if task.SlaveName and task.SlaveName.startswith("ip-10-"):
            return True, "spot"

    return False, None
```

**Region derivation from AZ:**

`describe-instances` returns `Placement.AvailabilityZone` (e.g. `us-west-2a`), not a
separate `region` field. Region is derived from AZ:

```python
def az_to_region(az):
    """'us-west-2a' → 'us-west-2'. Strips the trailing letter."""
    return az[:-1]
```

**Worker → instance ID resolution:**

Same logic as `compute_job_cost.sh` lines 173-192:

```python
def resolve_to_instance_ids(worker_hostnames, region):
    """
    Resolve Deadline worker hostnames to EC2 instance IDs.
    Matches compute_job_cost.sh lines 173-192.

    Two paths per hostname:
    1. If hostname is already an instance ID (i-xxxxx): use directly.
    2. Else: ec2 describe-instances --filter private-dns-name=<hostname>*
    """
    import boto3
    ec2 = boto3.client("ec2", region_name=region)
    instance_ids = []

    for hostname in worker_hostnames:
        if re.match(r"^i-[a-f0-9]+$", hostname):
            instance_ids.append(hostname)
        else:
            resp = ec2.describe_instances(
                Filters=[
                    {"Name": "private-dns-name", "Values": [hostname + "*"]},
                    {"Name": "instance-state-name",
                     "Values": ["running", "stopped", "terminated"]},
                ]
            )
            for res in resp.get("Reservations", []):
                for inst in res.get("Instances", []):
                    instance_ids.append(inst["InstanceId"])

    return list(set(instance_ids))  # deduplicate
```

**Per-instance render_hours computation (task-level, not job-level):**

A job running 3.2h across 4 instances does NOT mean each instance was busy for 3.2h.
Per-instance hours must be derived from **task-level** data — each task has a slave
assignment, a start time, and an end time. Summing task durations per instance gives
the correct per-instance active time.

`compute_job_cost.sh` has this flaw (uses job-level hours × single price), but the
plugin fixes it:

```python
def compute_per_instance_hours(tasks):
    """
    Returns {instance_id: render_hours} from task-level data.

    Deadline tasks have:
      task.SlaveName  — worker hostname (resolvable to instance ID)
      task.StartTime   — task start
      task.EndTime     — task end
    """
    instance_hours = defaultdict(float)

    for task in tasks:
        if not task.SlaveName or not task.StartTime or not task.EndTime:
            continue
        hostname = task.SlaveName
        # Resolve hostname → instance_id (cached from resolve_to_instance_ids)
        iid = hostname_to_instance.get(hostname)
        if not iid:
            continue
        duration = (task.EndTime - task.StartTime).total_seconds() / 3600.0
        instance_hours[iid] += duration

    return dict(instance_hours)
```

**Full plugin pseudocode (OnJobFinished):**

```python
import json, re, boto3, threading
from datetime import datetime, timedelta, timezone
from collections import defaultdict
from Deadline.Scripting import RepositoryUtils

def OnJobFinished(self, job, startTime, endTime):
    try:
        # 1. Detect whether this is an AWS job
        is_aws, job_type = is_aws_job(job)
        if not is_aws:
            return

        config = self.GetConfig()
        region = config.AWSRegion
        api_timeout = int(config.ApiTimeoutSeconds)
        max_retries = int(config.MaxRetryAttempts)

        # 2. Get task list with slave assignments
        tasks = RepositoryUtils.GetJobTasks(job.JobId, True)

        # 3. Extract worker hostnames, resolve → instance IDs
        worker_hostnames = {t.SlaveName for t in tasks if t.SlaveName}
        instance_ids = resolve_to_instance_ids(worker_hostnames, region)
        hostname_to_instance = build_hostname_map(worker_hostnames, instance_ids, region)

        # 4. Compute per-instance render hours from TASK data
        instance_hours = compute_per_instance_hours(tasks, hostname_to_instance)

        # 5. Get instance metadata (type, AZ, lifecycle, launch_time) per instance
        instance_infos = {}
        for iid in instance_ids:
            info = get_instance_info(iid, region, api_timeout, max_retries)
            instance_infos[iid] = info

        # 6. Compute cost per instance, then sum
        total_render_cost = 0.0
        total_instance_cost = 0.0
        total_render_hours = 0.0
        per_instance_details = []

        for iid, info in instance_infos.items():
            render_hours_i = instance_hours.get(iid, 0.0)
            inst_region = az_to_region(info.az)

            # Determine price: spot or on-demand fallback
            if info.lifecycle == "spot":
                price_i, pricing_source_i = get_avg_spot_price(
                    info.type, info.az, startTime, endTime,
                    inst_region, api_timeout, max_retries
                )
            else:
                price_i, pricing_source_i = get_on_demand_price(
                    info.type, inst_region, api_timeout, max_retries
                )

            render_cost_i = render_hours_i * price_i
            instance_cost_i = compute_instance_cost(
                info.launch_time, endTime, price_i
            )

            total_render_cost += render_cost_i
            total_instance_cost += instance_cost_i
            total_render_hours += render_hours_i

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

        # 7. Compute volume-weighted average spot price
        if total_render_hours > 0:
            weighted_avg_price = total_render_cost / total_render_hours
        else:
            weighted_avg_price = 0.0

        # Determine majority pricing source for CSV
        pricing_sources = [d.get("pricing_source", "spot") for d in per_instance_details]
        majority_source = max(set(pricing_sources), key=pricing_sources.count)

        # 8. Write to Deadline ExtraInfo
        cost_json = {
            "phase": "estimate",
            "job_type": job_type,
            "render_cost": round(total_render_cost, 2),
            "instance_cost": round(total_instance_cost, 2),
            "render_hours": round(total_render_hours, 2),
            "instances": per_instance_details,
            "computed_at": datetime.now(timezone.utc).isoformat()
        }
        RepositoryUtils.SetJobExtraInfo(job.JobId, 1980, json.dumps(cost_json))
        RepositoryUtils.SetJobExtraInfo(job.JobId, 1981,
            f"estimated:${total_render_cost:.2f} ({len(instance_ids)} inst, "
            f"{total_render_hours:.1f}h {job_type})")

        # 9. Log to JSONL for reconciliation
        append_cost_log(job.JobId, cost_json)

        # 10. Write per-job CSV report
        write_job_cost_csv(job, cost_json, weighted_avg_price, majority_source)

        # 11. Alert if over threshold
        threshold = float(config.CostAlertThreshold)
        if total_render_cost > threshold:
            send_alert(job, total_render_cost)

    except Exception as e:
        # NEVER let plugin errors block the Deadline event pipeline
        self.LogError(f"AwsJobCostObserver error: {e}")
        self.LogWarning("Cost observation skipped for this job — "
                         "see Deadline event log for details.")
```

> **Note:** The `try/except` wrapping the entire body ensures that ANY error (AWS API
> failure, Deadline API change, malformed data) is caught, logged, and does NOT block
> the event pipeline. The job still completes normally; only cost tracking is skipped.

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
4. Worker hostname matches EC2 pattern (`ip-10-*`, `.compute.internal`) → AWS
5. Otherwise → not AWS, skip

**`job_type` → `is_portal` mapping (authoritative):**

The detection function returns `job_type` as `"spot"` or `"portal"`. The CSV `is_portal`
column is derived explicitly:

```
is_portal = (job_type == "portal")
```

This means Portal-managed jobs (detected via ExtraInfo2000 or `awsportal` pool) set
`is_portal = true`. Direct-spawn spot workers always set `is_portal = false`.

### C. Instance-to-job mapping & cost computation

**Multi-instance aware (per-instance task durations):**

A single Deadline job often spans **multiple EC2 instances** (e.g., 240 frames
distributed across 4 spot workers). Each instance may be a **different type** in a
**different AZ** with a **different spot price**. Critically, each instance is active
for a **different duration** (derived from task-level data, not the job-level window).

```
Job 65a3f1b2 (240 frames):
  Task-level analysis:
    Tasks 1-60   → instance i-0abc123: 2.1h active
    Tasks 61-120 → instance i-0def456: 1.1h active
    Tasks 121-180→ instance i-0ghi789: 0.5h active
    Tasks 181-240→ instance i-0jkl012: 1.0h active
                                    Total render_hours: 4.7h (not 3.2h!)

  Cost:
    i-0abc123 (g6e.4xlarge, us-west-2a, spot, $0.72/hr, 2.1h) → $1.51
    i-0def456 (g6e.4xlarge, us-west-2b, spot, $0.68/hr, 1.1h) → $0.75
    i-0ghi789 (g6.xlarge,  us-west-2a, spot, $0.35/hr, 0.5h) → $0.18
    i-0jkl012 (g6e.4xlarge, us-west-2a, spot, $0.72/hr, 1.0h) → $0.72
                                                    Total render_cost → $3.16
```

Each instance's cost is computed independently using its own type, AZ, lifecycle
(spot vs on-demand), and **task-level** active duration. The job's total is the sum.

> **Difference from `compute_job_cost.sh`:** The shell script uses job-level
> `render_hours` (single number) × single average price, which over-counts for
> multi-instance jobs. The plugin fixes this by parsing task-level data to get
> per-instance active time.

### D. Pricing model (spot + on-demand fallback)

The plugin handles both spot and on-demand (Portal) instances:

| Instance lifecycle | Pricing source | Method |
|--------------------|----------------|--------|
| **Spot** (direct-spawn workers) | `DescribeSpotPriceHistory` | Average spot price during the instance's active window |
| **On-demand** (Portal-managed, or spot with no history) | AWS Price List API (`pricing/GetProducts`) | Public on-demand rate for the instance type + region |

**Spot fallback chain:** If `DescribeSpotPriceHistory` returns no data for the
window (instance was a new type, or the window is outside the 90-day history), the
plugin falls back to on-demand price from the Price List API and flags the estimate
with `"pricing_source": "on_demand_fallback"` in the per-instance JSON detail.

### E. Deadline ExtraInfo field map

Deadline provides 100 user-defined ExtraInfo fields (0-99) and 100 custom
ExtraInfo fields (1980-2000+). The AwsJobCostObserver uses fields in the custom
range to avoid collision with user-defined fields.

| Field | Owner | Purpose |
|------|-------|---------|
| `ExtraInfo2000` | **AWS Portal** (existing) | Portal metadata (instance ID, fleet info) — read by `compute_job_cost.sh` for Portal detection. **Do not modify.** |
| `ExtraInfo1980` | **AwsJobCostObserver** (this spec) | Phase 1 cost estimate JSON (machine-readable) |
| `ExtraInfo1981` | **AwsJobCostObserver** (this spec) | Human-readable cost summary string |
| `ExtraInfo1982` | **AwsJobCostObserver** (this spec) | Phase 2 reconciled cost JSON (after reconciliation) |

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
| 5 | `plugin` | string | `Houdini` | Deadline plugin |
| 6 | `pool` | string | `awsportal` | Deadline pool |
| 7 | `group` | string | `aws-spot-east` | Deadline group |
| 8 | `is_portal` | bool | `true` | Whether this was a Portal-managed job. Derived: `is_portal = (job_type == "portal")` |
| 9 | `frames` | string | `1-240` | Frame range |
| 10 | `render_start` | ISO 8601 | `2026-06-24T14:00:00Z` | Job render start (UTC) |
| 11 | `render_end` | ISO 8601 | `2026-06-24T17:12:34Z` | Job render end (UTC) |
| 12 | `render_hours` | float | `4.70` | Sum of all per-instance render hours (from task-level data) |
| 13 | `instance_ids` | string (semicolon-delimited) | `i-0abc123;i-0def456` | All EC2 instances that rendered this job |
| 14 | `instance_types` | string (semicolon-delimited) | `g6e.4xlarge;g6.xlarge` | Instance types (aligned with instance_ids by position) |
| 15 | `az` | string (semicolon-delimited) | `us-west-2a;us-west-2b` | AZs (aligned with instance_ids by position) |
| 16 | `phase` | string | `estimate` | `estimate` (Phase 1) or `reconciled` (Phase 2 after reconciliation) |
| 17 | `pricing_source` | string | `spot` | Majority pricing source across instances: `spot`, `on_demand`, or `on_demand_fallback` |
| 18 | `weighted_avg_price_hr` | float | `0.6723` | **Volume-weighted** average price: `Σ(price_i × hours_i) / Σ(hours_i)`. For heterogeneous jobs this accounts for different instance types and durations. |
| 19 | `render_cost` | float | `3.16` | **Authoritative job cost.** Compute cost for the render duration only ($) |
| 20 | `instance_cost` | float | `4.89` | Instance cost from launch to termination ($) |
| 21 | `actual_cost` | float | *(empty)* | CUR 2.0 actual cost (empty until Phase 2 reconciliation) |
| 22 | `variance_pct` | float | *(empty)* | `(actual - estimate) / actual × 100` (empty until Phase 2) |
| — | `currency` | string | `USD` | Always USD |
| — | `computed_at` | ISO 8601 | `2026-06-24T17:12:35Z` | When this report was generated |

> `currency` and `computed_at` are always appended as the final two columns but are
> metadata, not numbered cost columns. The 22 numbered columns are the core schema;
> total CSV width is 24 columns.

**Cost definitions (authoritative):**

- **`render_cost`** is the **authoritative job cost**. It represents compute cost for
  the actual render time per instance (summed across all instances), not instance
  lifetime. This is what alerts, reconciliation, and reporting use.
- **`instance_cost`** is supplementary. It covers launch → termination (includes boot
  time, health-check delay, deregistration). Useful for TCO analysis but not per-job billing.

**Example CSV file:**

```csv
job_id,job_name,submitted_by,status,plugin,pool,group,is_portal,frames,render_start,render_end,render_hours,instance_ids,instance_types,az,phase,pricing_source,weighted_avg_price_hr,render_cost,instance_cost,actual_cost,variance_pct,currency,computed_at
65a3f1b2,Portal_AMI_Test_Render,howong,Completed,Houdini,awsportal,,true,1-240,2026-06-24T14:00:00Z,2026-06-24T17:12:34Z,4.70,i-0abc123;i-0def456,g6e.4xlarge;g6.xlarge,us-west-2a;us-west-2b,estimate,spot,0.6723,3.16,4.89,,,USD,2026-06-24T17:12:35Z
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

## Error handling & resilience

**The `OnJobFinished` event is synchronous.** If the plugin blocks (AWS API hang,
network timeout), it blocks the entire Deadline event pipeline — all subsequent job
completions, slave events, etc. are delayed. This is the single biggest runtime risk.

### Design rules

1. **All AWS API calls have timeouts.** Each `boto3` call is wrapped in a thread with
   `ApiTimeoutSeconds` (default 30s). If the thread doesn't complete in time, the call
   is abandoned.

2. **All AWS API calls have retries.** `MaxRetryAttempts` (default 2) with exponential
   backoff. After max retries, the plugin logs the error and continues.

3. **Top-level try/except.** The entire `OnJobFinished` body is wrapped in try/except.
   Any uncaught exception is logged via `self.LogError()` and the plugin returns without
   blocking. Cost tracking is skipped for that job; the job itself completes normally.

4. **Missing data does not crash.** If an instance ID can't be resolved, the instance
   is skipped with a warning. If spot price returns empty, the on-demand fallback is
   used. If ALL instances fail, `render_cost = $0.00` with `pricing_source = "error"`
   and a log warning — never a crash.

5. **No blocking I/O outside try/except.** File writes (JSONL, CSV) are also wrapped.
   If disk is full or permission denied, the plugin logs and continues.

```python
def call_with_timeout(fn, timeout, *args, **kwargs):
    """Run an AWS API call in a thread with timeout."""
    result = [None]
    exc = [None]

    def worker():
        try:
            result[0] = fn(*args, **kwargs)
        except Exception as e:
            exc[0] = e

    t = threading.Thread(target=worker, daemon=True)
    t.start()
    t.join(timeout)

    if t.is_alive():
        raise TimeoutError(f"API call exceeded {timeout}s timeout")
    if exc[0]:
        raise exc[0]
    return result[0]
```

---

## Reconciliation (Phase 2)

### Cross-job allocation algorithm

When multiple jobs share the same instance in the same billing hour, costs must be
allocated proportionally. The allocation requires **cross-job context** — the cron
must know which OTHER jobs ran on the same instance during overlapping hours.

**How the cron finds overlapping jobs:**

1. The `cost_observer.jsonl` log records every job's `instance_ids`, `render_start`,
   `render_end`, and per-instance `render_hours` (from Phase 1).
2. For each job being reconciled, the cron scans ALL JSONL entries for any entry whose
   `instance_ids` overlap with the target job's instances AND whose time window overlaps.
3. This gives the complete set of jobs sharing each instance during the relevant hours.

```python
def find_overlapping_jobs(target_job, all_jobs_jsonl):
    """
    Scan JSONL log for jobs that share instances and overlap in time.
    Returns {instance_id: [job_entry, ...]} for allocation.
    """
    overlapping = defaultdict(list)

    for entry in all_jobs_jsonl:
        shared_instances = set(entry["instance_ids"]) & set(target_job["instance_ids"])
        if not shared_instances:
            continue

        # Check time overlap
        entry_start = parse(entry["render_start"])
        entry_end = parse(entry["render_end"])
        target_start = parse(target_job["render_start"])
        target_end = parse(target_job["render_end"])

        if entry_end < target_start or entry_start > target_end:
            continue  # no time overlap

        for iid in shared_instances:
            overlapping[iid].append(entry)

    return overlapping
```

**Allocation:**

1. Query CUR 2.0 for the instance's total cost during the job window
2. Sum the render_hours of all jobs on that instance during that hour (from JSONL)
3. Allocate: `job_cost = hourly_cost × (job_render_hours / total_render_hours_in_hour)`
4. Sum allocated costs across all hours the instance was alive

**Why render_hours (not frames or tasks):** render hours directly correlate to compute
consumed. A job rendering 10 frames in 2 hours consumes the same GPU as a job rendering
200 frames in 2 hours on the same GPU type.

**Example:**

```
Instance i-0abc123, us-west-2a, g6e.4xlarge, hour 14:00-15:00 UTC:
  CUR cost: $0.72 (1 hour spot)
  Jobs active in this hour (from JSONL scan):
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
- **Job not in JSONL (submitted before plugin was installed):** Skip — can't allocate
  without per-instance hours. Log a warning.

---

## Relationship to existing code

| Existing artifact | Relationship |
|---|---|
| `aws/compute_job_cost.sh` | **Direct reuse** — Phase 1/2 logic is the conceptual basis. The shell script remains as a manual CLI fallback. The plugin **fixes** the script's multi-instance flaw by using task-level durations. |
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

## Prerequisites (verify before Phase 1 implementation)

| ID | Task | How to verify | Blocks |
|----|------|---------------|--------|
| **P1** | ExtraInfo 1980-1982 unused by existing plugins | Run field-check script (see ExtraInfo field map section) on RCS host | Phase 1 |
| **P2** | AWS CLI works from RCS host WSL | `aws sts get-caller-identity` from WSL shell | Phase 1 |
| **P3** | IAM permissions for cost APIs | Policy includes `ec2:DescribeInstances`, `ec2:DescribeSpotPriceHistory`, `pricing:GetProducts` | Phase 1 |
| **P4** | Deadline Python event plugin API version | Submit a minimal test plugin that logs `"hello"` on `OnJobFinished`; verify exact method signatures for `RepositoryUtils.GetJobTasks`, `SetJobExtraInfo`, etc. | Phase 1 |
| **P5** | CUR 2.0 + Athena configured (optional) | `aws athena get-table-metadata` on CUR table | Phase 2 only |

---

## Implementation phases & task breakdown

### Phase 1 — Event Plugin (estimate-only)

| Task | Deliverable | Test |
|------|-------------|------|
| **1.1** Plugin scaffold | Directory structure, `eventplugine.config`, `AwsJobCostObserver.py` with `OnJobFinished` callback | Plugin loads in Deadline without error; shows in Configure Plugins list |
| **1.2** AWS job detection (`is_aws_job`) | 4-method detection function | Unit test with mock job objects covering all 5 submission paths (4 AWS + 1 on-prem) |
| **1.3** Worker→instance resolution (`resolve_to_instance_ids`) | Hostname → EC2 instance ID via `describe-instances` | Given hostname `ip-10-0-1-2`, returns correct instance ID via mock AWS |
| **1.4** Instance metadata (`get_instance_info`) | Per-instance type, AZ, lifecycle, launch_time | Given instance ID, returns correct metadata from `describe-instances` |
| **1.5** Spot price query (`get_avg_spot_price`) | `DescribeSpotPriceHistory` wrapper | Given type+AZ+time window, returns average price ±5% of known value |
| **1.6** On-demand fallback (`get_on_demand_price`) | `pricing/GetProducts` wrapper | Given instance type, returns on-demand rate matching AWS calculator |
| **1.7** Per-instance render hours (`compute_per_instance_hours`) | Task-level duration parsing per instance | 4 instances with different task assignments → correct per-instance hours |
| **1.8** Multi-instance cost computation | Per-instance cost loop + sum + weighted avg | 4 instances (2 types, 2 AZs) → correct per-instance and total costs |
| **1.9** ExtraInfo writing | ExtraInfo1980/1981 via `SetJobExtraInfo` | After plugin runs, `GetJobExtraInfo(id, 1980)` returns valid JSON |
| **1.10** CSV report writing | 22-column CSV to `job_cost_reports/` | CSV file exists, parses in Python `csv` module, all columns present |
| **1.11** JSONL logging | Append to `cost_observer.jsonl` | Entry written with instance_ids, timing, render_hours |
| **1.12** Error handling | try/except + timeouts + non-blocking | Mock AWS failure → plugin logs error, does NOT block event pipeline |
| **1.13** Integration test | Full pipeline on real Deadline | Submit test render → ExtraInfo, JSONL, CSV all correct |

**Dependencies:** 1.1 → all others. 1.2 is independent. 1.3 → 1.4 → 1.7 → 1.8.
1.5 and 1.6 are independent (can parallelize). 1.9, 1.10, 1.11 depend on 1.8.
1.12 wraps all. 1.13 depends on everything.

### Phase 2 — CUR Reconciliation

| Task | Deliverable | Test |
|------|-------------|------|
| **2.1** CUR 2.0 setup runbook | AWS console steps + Athena table verification | Athena query `SELECT COUNT(*) FROM cur_2_0` returns rows |
| **2.2** Athena query implementation | Per-instance, time-windowed CUR query | Query returns correct cost for a known instance+date |
| **2.3** Cross-job allocation | Read JSONL, find overlapping jobs, proportional split | Two jobs sharing one instance → correct proportional allocation |
| **2.4** CSV update logic | Find CSV by `job_id_*` glob, update in-place | Phase 2 CSV has `actual_cost` + `variance_pct` filled, `phase=reconciled` |
| **2.5** ExtraInfo1982 writing | Write reconciled cost JSON to ExtraInfo1982 | `GetJobExtraInfo(id, 1982)` returns valid JSON with `phase: "reconciled"` |
| **2.6** Variance flagging | >10% variance → log warning + Deadline alert | Mock estimate=$3.16, actual=$4.50 → 42% variance flagged |
| **2.7** Cron scheduling + monitoring | systemd timer / Windows Task Scheduler entry | Cron runs daily at 06:00 UTC, processes previous day's jobs |

**Dependencies:** 2.1 → 2.2 → 2.3 → 2.4/2.5/2.6. 2.7 depends on 2.1-2.6.

### Phase 3 — Dashboard (optional)

| Task | Deliverable | Test |
|------|-------------|------|
| **3.1** Weekly report generator (`cost_report.py`) | Reads all CSVs in `job_cost_reports/`, produces weekly summary | Report shows total spend, per-artist breakdown, top 5 most expensive jobs |
| **3.2** Per-artist breakdown | Group by `submitted_by` column | Correct aggregation matches manual CSV review |
| **3.3** Trend analysis | Cost per frame over time | Chart shows trend line |

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
    cost_reconcile.py          # Daily reconciliation cron (Phase 2)
    cost_report.py             # Weekly report generator (Phase 3)
```

---

## Exit criteria (Phase 1)

- [ ] Submit a render job to an AWS pool → job completes → `ExtraInfo1980` populated
- [ ] `ExtraInfo1981` shows human-readable cost summary in Deadline Monitor
- [ ] JSONL log entry written with correct instance IDs and per-instance timing
- [ ] Per-job CSV written to `job_cost_reports/<job_id>_<name>_<timestamp>.csv`
- [ ] CSV contains all 22 columns + currency + computed_at with correct values
- [ ] Multi-instance job: each instance's cost computed independently from task data
      (verify with a job spanning 2+ instances of different types)
- [ ] `render_hours` in CSV = sum of per-instance hours (NOT job wall-clock time)
- [ ] `weighted_avg_price_hr` reflects volume-weighted average, not single price
- [ ] Portal (on-demand) job: cost computed via Price List API, not $0
- [ ] Failed job: cost computed and logged (verify OnJobFinished fires for Failed)
- [ ] Cost within ±10% of `compute_job_cost.sh` for the same job
- [ ] Non-AWS jobs (no AWS pool, group, ExtraInfo2000, or EC2 hostname) are skipped
- [ ] Cost threshold alert fires when job exceeds `$CostAlertThreshold`
- [ ] AWS API failure: plugin logs error, does NOT block Deadline event pipeline
- [ ] All Deadline API calls use `RepositoryUtils.*` (not CLI `deadlinecommand`)

## Exit criteria (Phase 2)

- [ ] CUR 2.0 + Athena configured and queryable
- [ ] Daily cron processes all jobs from previous day
- [ ] CSV files updated in-place with `actual_cost` + `variance_pct`
- [ ] `ExtraInfo1982` populated with reconciled cost JSON
- [ ] Cross-job allocation correct: two jobs sharing one instance → proportional split
- [ ] Variance >10% flagged in reconciliation report
- [ ] CUR data delayed >48h → skip, retry next day, alert after 72h

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
| 7 | Task-level StartTime/EndTime format in Deadline Python API — epoch? ISO string? DateTime? | Verified during Prerequisite P4. Normalize to Python datetime. |

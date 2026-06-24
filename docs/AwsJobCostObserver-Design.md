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
| **Phase 1 — Estimate** | Job completes (immediate) | `DescribeSpotPriceHistory` + instance runtime | ±5-10% | 0 min |
| **Phase 2 — Actual** | Next day (scheduled) | CUR 2.0 via Athena, queried by `resource_id` | Exact | 8-24h |

This design reuses the logic from `compute_job_cost.sh` but wraps it in an automated
event-driven pipeline instead of manual CLI invocation.

---

## Architecture

```
 Deadline Job Completes
        │
        ▼
 ┌──────────────────────────┐
 │  OnJobFinished event     │     Deadline Event Plugin (this component)
 │  (AwsJobCostObserver)    │
 └──────────┬───────────────┘
            │
            ├─► 1. Query Deadline for job metadata
            │      (start time, end time, workers, plugin, pool)
            │
            ├─► 2. Resolve worker hostnames → EC2 instance IDs
            │      (describe-instances by private DNS)
            │
            ├─► 3. Get instance type + AZ from EC2 metadata
            │
            ├─► 4. Query DescribeSpotPriceHistory for the job window
            │      Compute: Σ (avg_spot_price × render_hours)
            │
            ├─► 5. Write Phase 1 estimate to Deadline ExtraInfo fields
            │      ExtraInfo1980 = {"phase":"estimate","cost":"12.34", ...}
            │      ExtraInfo1981 = "estimated:$12.34 (g6e.4xlarge, 3.2h spot)"
            │
            └─► 6. Record job_id + instance_ids + timing to a local JSONL log
                   /opt/Thinkbox/Deadline10/reports/cost_observer.jsonl
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
```

---

## Component breakdown

### A. Deadline Event Plugin (`AwsJobCostObserver.py`)

**Location:** `/opt/Thinkbox/Deadline10/events/AwsJobCostObserver/` (on the RCS host)

**Event:** `OnJobFinished` — fires when any job transitions to `Completed` or `Failed`

**Config (eventplugine.config):**

```json
{
  "Version": 1,
  "Name": "AwsJobCostObserver",
  "Enabled": true,
  "Event": "OnJobFinished",
  "LimitToGroups": "aws-spot,aws-spot-east,awsportal",
  "Config": {
    "AWSRegion": "us-west-2",
    "CurDatabase": "deadline_cost",
    "CurTable": "cur_2_0",
    "AthenaOutputBucket": "s3://deadline-cost-athena-results/",
    "CostAlertThreshold": "50.00",
    "ReconciliationEnabled": true
  }
}
```

`LimitToGroups` ensures the observer only fires for AWS-rendered jobs — local
on-prem jobs in the `none` pool are skipped.

**Plugin logic (Python, runs on the Deadline RCS host):**

```python
# Pseudocode — actual implementation in AwsJobCostObserver.py

def OnJobFinished(job, startTime, endTime):
    # 1. Skip non-AWS jobs
    if job.Pool not in AWS_POOLS and job.Group not in AWS_GROUPS:
        return

    # 2. Get workers that rendered this job
    tasks = deadline.GetJobTasks(job.ID)
    worker_hostnames = {t.SlaveName for t in tasks}
    instance_ids = resolve_to_instance_ids(worker_hostnames, region)

    # 3. Get instance metadata
    instance_type, az, launch_time = get_instance_info(instance_ids[0], region)

    # 4. Compute render hours
    render_hours = (endTime - startTime).total_seconds() / 3600

    # 5. Query spot price history for the job window
    avg_price = get_avg_spot_price(instance_type, az, startTime, endTime, region)

    # 6. Compute costs
    render_cost = render_hours * avg_price
    instance_cost = compute_instance_cost(launch_time, endTime, avg_price)

    # 7. Write to Deadline ExtraInfo
    cost_json = {
        "phase": "estimate",
        "render_cost": round(render_cost, 2),
        "instance_cost": round(instance_cost, 2),
        "instance_type": instance_type,
        "render_hours": round(render_hours, 2),
        "avg_spot_price": round(avg_price, 4),
        "instance_ids": instance_ids,
        "computed_at": datetime.utcnow().isoformat() + "Z"
    }
    deadline.SetJobSetting(job.ID, "ExtraInfo1980", json.dumps(cost_json))
    deadline.SetJobSetting(job.ID, "ExtraInfo1981",
        f"estimated:${render_cost:.2f} ({instance_type}, {render_hours:.1f}h spot)")

    # 8. Log to JSONL for reconciliation
    append_cost_log(job.ID, cost_json)

    # 9. Write per-job CSV report
    write_job_cost_csv(job.ID, job.Name, cost_json)

    # 10. Alert if over threshold
    if render_cost > float(config.CostAlertThreshold):
        send_alert(job, render_cost)
```

### B. Instance-to-job tagging strategy

**Problem:** CUR 2.0 line items have `resource_id` (instance ID) but no job ID. To
reconcile per-job costs, we need a way to map instance → job in CUR.

**Two approaches:**

| Approach | How | Pros | Cons |
|----------|-----|------|------|
| **A — EC2 tag at launch** | Tag instances with `deadline-job-id=<job>` at launch | Appears in CUR as cost allocation tag | Hard: instances are launched before the job is assigned to them; workers render multiple jobs |
| **B — Time-window correlation** | Query CUR by `resource_id` for the job's exact start/end window | No tagging needed; exact | CUR is hourly granularity; partial-hour jobs overlap billing windows |

**Decision: Approach B** (time-window correlation). Workers render multiple jobs and
are shared. A single worker instance may process 5 jobs in an hour. Tagging per-job
doesn't work for shared workers. Instead, the reconciliation step queries CUR for
each instance's cost during the specific time window, then allocates proportionally.

### C. Reconciliation cron (`cost_reconcile.py`)

**Schedule:** Daily at 06:00 UTC (cron on the RCS host)

**Input:** `/opt/Thinkbox/Deadline10/reports/cost_observer.jsonl` — jobs logged in the
last 48h that have Phase 1 estimates but no Phase 2 actuals.

**Process:**
1. Read un-reconciled jobs from JSONL log
2. For each job, query Athena (CUR 2.0) for each `resource_id` in the job window:
   ```sql
   SELECT line_item_resource_id,
          line_item_usage_start_date,
          line_item_usage_end_date,
          line_item_unblended_cost,
          pricing_term
   FROM deadline_cost.cur_2_0
   WHERE line_item_resource_id IN ('i-0abc123', 'i-0def456')
     AND line_item_usage_start_date >= TIMESTAMP '${JOB_START}'
     AND line_item_usage_end_date   <= TIMESTAMP '${JOB_END}'
     AND line_item_product_code = 'AmazonEC2'
   ```
3. Sum actual costs for the instance(s) during the job window
4. Proportionally allocate if multiple jobs shared the same instance in the same hour
5. Update Deadline ExtraInfo:
   - `ExtraInfo1982` = actual cost JSON (Phase 2)
   - `ExtraInfo1981` updated to show both estimate and actual
6. Update per-job CSV in `job_cost_reports/`: fill `actual_cost`, `variance_pct`,
   change `phase` from `estimate` to `reconciled`
7. Flag variance > 10% in the JSONL log and Deadline Monitor

### D. Deadline Monitor integration

The ExtraInfo fields surface in Deadline Monitor's job list columns:

| ExtraInfo field | Example value | Display |
|-----------------|---------------|---------|
| `ExtraInfo1980` | `{"phase":"estimate","render_cost":12.34,...}` | JSON (machine-readable) |
| `ExtraInfo1981` | `estimated:$12.34 (g6e.4xlarge, 3.2h spot)` | Human-readable summary |
| `ExtraInfo1982` | `{"phase":"actual","cost":11.87,...}` | Phase 2 actuals (next day) |

Deadline admins can add custom columns to the Monitor's job list view showing
`ExtraInfo1981` so every job shows its cost at a glance.

### E. Cost alert thresholds

Alerts are sent via Deadline's built-in notification system (email / Slack webhook).

| Condition | Action |
|-----------|--------|
| Single job cost > `$CostAlertThreshold` (default $50) | Email job submitter + admin |
| Daily aggregate AWS spend > $500 | Email admin (computed from JSONL log) |
| Estimate vs actual variance > 10% | Log warning in reconciliation report |

### F. Per-job CSV reports

Every job that completes also writes an individual CSV cost report to a
`job_cost_reports/` subfolder. This gives a permanent, portable, per-job cost
record that can be opened in Excel, shared with producers, or ingested by
downstream billing systems.

**Location:** `/opt/Thinkbox/Deadline10/reports/job_cost_reports/`

**Filename:** `<job_id>_<job_name_sanitized>_<YYYYMMDD-HHMMSS>.csv`

Example: `65a3f1b2_portal_ami_test_render_20260624-143052.csv`

**CSV schema (columns):**

| Column | Type | Example | Description |
|--------|------|---------|-------------|
| `job_id` | string | `65a3f1b2` | Deadline job ID |
| `job_name` | string | `Portal_AMI_Test_Render` | Job name from Deadline |
| `status` | string | `Completed` | Final job status |
| `plugin` | string | `Houdini` | Deadline plugin |
| `pool` | string | `awsportal` | Deadline pool |
| `is_portal` | bool | `true` | Whether this was a Portal-managed job |
| `frames` | string | `1-240` | Frame range |
| `render_start` | ISO 8601 | `2026-06-24T14:00:00Z` | Job render start (UTC) |
| `render_end` | ISO 8601 | `2026-06-24T17:12:34Z` | Job render end (UTC) |
| `render_hours` | float | `3.21` | Total render duration in hours |
| `instance_ids` | string (semicolon-delimited) | `i-0abc123;i-0def456` | EC2 instances that rendered this job |
| `instance_type` | string | `g6e.4xlarge` | EC2 instance type |
| `az` | string | `us-west-2a` | Availability zone |
| `phase` | string | `estimate` | `estimate` (Phase 1) or `actual` (Phase 2 after reconciliation) |
| `avg_spot_price_hr` | float | `0.7234` | Average spot price during job window ($/hr) |
| `render_cost` | float | `2.32` | Compute cost for the render duration ($) |
| `instance_cost` | float | `2.89` | Total instance cost from launch to termination ($) |
| `actual_cost` | float | `` | CUR 2.0 actual cost (empty until Phase 2 reconciliation) |
| `variance_pct` | float | `` | `(actual - estimate) / actual × 100` (empty until Phase 2) |
| `currency` | string | `USD` | Always USD |
| `computed_at` | ISO 8601 | `2026-06-24T17:12:35Z` | When this report was generated |

**Example CSV file:**

```csv
job_id,job_name,status,plugin,pool,is_portal,frames,render_start,render_end,render_hours,instance_ids,instance_type,az,phase,avg_spot_price_hr,render_cost,instance_cost,actual_cost,variance_pct,currency,computed_at
65a3f1b2,Portal_AMI_Test_Render,Completed,Houdini,awsportal,true,1-240,2026-06-24T14:00:00Z,2026-06-24T17:12:34Z,3.21,i-0abc123;i-0def456,g6e.4xlarge,us-west-2a,estimate,0.7234,2.32,2.89,,,USD,2026-06-24T17:12:35Z
```

**Behavior:**

- **Phase 1 (estimate):** Written immediately on job completion. `actual_cost` and
  `variance_pct` columns are empty.
- **Phase 2 (actual):** The reconciliation cron updates the same file in-place,
  filling in `actual_cost`, `variance_pct`, and changing `phase` from `estimate`
  to `reconciled`.
- **Job name sanitization:** Job names are stripped of filesystem-unsafe characters
  (`/ \ : * ? " < > |`) and truncated to 50 chars to form the filename.
- **Deduplication:** The `<job_id>` prefix in the filename guarantees uniqueness.
  If a CSV already exists for a job_id, the Phase 2 update overwrites it rather
  than creating a duplicate.
- **Permissions:** Files are owned by the Deadline service account (`ec2-user`)
  with mode `644` so they can be read by any user for reporting.
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
   - Activate tag key: `project` (so `project=deadline-worker` appears in CUR)

4. **IAM permissions** for the RCS host role:
   ```
   ce:GetCostAndUsage
   athena:StartQueryExecution, GetQueryExecution, GetQueryResults
   ec2:DescribeInstances, DescribeSpotPriceHistory
   s3:GetObject (for CUR bucket)
   ```

### Deadline-side setup

1. Install plugin to `/opt/Thinkbox/Deadline10/events/AwsJobCostObserver/`
2. Configure `eventplugine.config` with region, CUR table, thresholds
3. Restart Deadline Pulse
4. Verify: submit a test render → check `ExtraInfo1980` appears

---

## Open questions

| # | Question | Default if unresolved |
|---|----------|-----------------------|
| 1 | Should cost data persist after jobs are deleted from Deadline? | Yes — JSONL log is the permanent record |
| 2 | Should Portal path (no spot price) use on-demand price for estimate? | Yes — fall back to Price List API if no spot history |
| 3 | How to handle multi-region jobs (us-west-2 + us-east-1 failover)? | Query spot price per-instance-region, not job-level |
| 4 | Should artists see cost in Deadline Monitor, or admin-only? | Admin-only initially; artist visibility is Phase 2 |
| 5 | CUR Athena query timeout — what if CUR data is delayed >48h? | Skip reconciliation, retry next day, alert after 72h |

---

## Implementation phases

### Phase 1 — Event Plugin (estimate-only)
- Implement `AwsJobCostObserver.py` Deadline Event Plugin
- OnJobFinished → compute Phase 1 spot estimate
- Write to ExtraInfo1980/1981
- Log to JSONL
- Write per-job CSV to `job_cost_reports/`
- Basic cost threshold alert
- **Deliverable:** Plugin file + config + install instructions

### Phase 2 — CUR Reconciliation
- Implement `cost_reconcile.py` daily cron
- Athena query per job for actuals
- Update ExtraInfo1982 with Phase 2 actuals
- Update CSV files in `job_cost_reports/` with actual_cost + variance_pct
- Variance flagging
- **Deliverable:** Cron script + Athena setup runbook

### Phase 3 — Dashboard (optional)
- Generate weekly cost report from CSV files in `job_cost_reports/`
- Per-show / per-artist cost breakdown
- Trend analysis (cost per frame over time)
- Export to CSV / spreadsheet
- **Deliverable:** Report generation script

---

## File layout (to be implemented)

```
deadline/events/AwsJobCostObserver/
    AwsJobCostObserver.py      # Event plugin (OnJobFinished)
    eventplugine.config        # Plugin config (JSON)
    cost_utils.py              # Shared cost computation logic
    README.md                  # Install + config instructions

deadline/reports/
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
- [ ] **Per-job CSV written to `job_cost_reports/<job_id>_<name>_<timestamp>.csv`**
- [ ] **CSV contains all 21 columns with correct values (spot price, render hours, costs)**
- [ ] Cost within ±10% of `compute_job_cost.sh` for the same job
- [ ] Non-AWS jobs (pool `none`) are skipped — no cost computed, no CSV written
- [ ] Cost threshold alert fires when job exceeds `$CostAlertThreshold`

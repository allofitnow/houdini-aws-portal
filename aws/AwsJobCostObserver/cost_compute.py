"""
cost_compute.py — Task-level render hours and multi-instance cost computation.

Computes the authoritative render_cost for a completed Deadline job based on
task report data and instance pricing.

Spec: docs/AwsJobCostObserver-Design.md § E11.5 — Cost computation
Issue: #118
"""

from __future__ import absolute_import, division, print_function

from collections import defaultdict
from datetime import datetime, timezone

from cost_helpers import (
    InstanceInfo,
    az_to_region,
    compute_instance_cost,
    get_avg_spot_price,
    get_instance_info,
    get_instances_batch,
    get_on_demand_price,
)

# ── Expense categories ────────────────────────────────────────────────────────

EXPENSE_CATEGORIES = {
    "render-compute":         "EC2 GPU instance hours",
    "render-storage":         "S3 I/O, B2 egress, Asset Server sync",
    "network-transfer":       "NAT Gateway, DataTransfer (private subnet)",
    "license-consumption":    "UBL license endpoint hours",
    "infrastructure-overhead": "Idle/leaked resources (NAT GW idle, EIPs)",
    "ami-baking":             "EC2 Image Builder, snapshots",
    "debugging-test":         "Jobs in test/debug groups",
}


def categorize_job(job_name, group, pool):
    """
    Determine the expense category for a job.
    Default: render-compute. Override: debugging-test for test/debug groups.
    """
    name_lower = (job_name or "").lower()
    group_lower = (group or "").lower()

    if any(x in name_lower for x in ["test", "debug", "e2e", "ubl_test"]):
        return "debugging-test"
    if any(x in group_lower for x in ["test", "debug"]):
        return "debugging-test"

    return "render-compute"


def parse_task_datetime(dt_str):
    """Parse Deadline task report datetime string. Handles multiple formats."""
    if not dt_str:
        return None
    if isinstance(dt_str, datetime):
        return dt_str
    # Handle ISO format with Z
    cleaned = str(dt_str).replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(cleaned)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except (ValueError, TypeError):
        pass
    # Handle Deadline's "2024-01-15 10:30:00" format
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y/%m/%d %H:%M:%S"):
        try:
            dt = datetime.strptime(str(dt_str), fmt)
            return dt.replace(tzinfo=timezone.utc)
        except (ValueError, TypeError):
            continue
    return None


def compute_render_hours(task_reports):
    """
    Sum per-worker render hours from task reports.

    Each task report has: WorkerName, StartTime, EndTime

    Returns: dict {worker_name: render_hours}
    """
    worker_hours = defaultdict(float)

    for report in task_reports:
        worker = report.get("WorkerName") or report.get("SlaveName")
        if not worker:
            continue

        start = parse_task_datetime(report.get("StartTime"))
        end = parse_task_datetime(report.get("EndTime"))

        if not start or not end:
            continue

        hours = (end - start).total_seconds() / 3600.0
        if hours > 0:
            worker_hours[worker] += hours

    return dict(worker_hours)


def compute_job_cost(
    worker_hostnames,
    worker_hours,
    region,
    hostname_map=None,
    instance_infos=None,
    api_timeout=30,
    max_retries=2,
):
    """
    Compute total render cost for a job.

    Args:
        worker_hostnames:  List of worker hostnames (from task reports)
        worker_hours:      dict {hostname: render_hours} from compute_render_hours()
        region:            AWS region (e.g., "us-west-2")
        hostname_map:      dict {hostname: instance_id} from build_hostname_map() (optional)
        instance_infos:    dict {instance_id: InstanceInfo} (optional, from pre-fetched data)
        api_timeout:       Per-API-call timeout in seconds
        max_retries:       Max retry attempts for AWS API calls

    Returns:
        dict with:
            render_cost:        float — total cost of render hours
            total_instance_cost: float — cost from instance launch to job end
            total_render_hours: float — sum of all worker render hours
            instance_details:   list of per-instance dicts
            pricing_source:     str — "on_demand", "spot", "on_demand_fallback"
            errors:             list of warning strings
    """
    errors = []
    instance_details = []
    total_render_cost = 0.0
    total_instance_cost = 0.0
    total_hours = 0.0

    # Group hours by instance (a single instance may render multiple tasks)
    for hostname in worker_hostnames:
        hours = worker_hours.get(hostname, 0.0)
        if hours <= 0:
            continue

        total_hours += hours

        # Resolve instance info
        instance_id = None
        if hostname_map:
            instance_id = hostname_map.get(hostname)

        info = None
        if instance_id and instance_infos and instance_id in instance_infos:
            info = instance_infos[instance_id]

        if not info or not instance_id:
            errors.append("Could not resolve instance for worker '%s'" % hostname)
            instance_details.append({
                "worker": hostname,
                "instance_id": None,
                "hours": hours,
                "rate": 0.0,
                "cost": 0.0,
                "lifecycle": "unknown",
                "error": "unresolved",
            })
            continue

        instance_region = az_to_region(info.az) if info.az else region

        # Get pricing based on lifecycle
        if info.lifecycle == "spot":
            price, source = get_avg_spot_price(
                info.type, info.az, None, None,
                instance_region, api_timeout, max_retries,
            )
            # For spot, pass task start/end as None (we don't have exact per-task times here)
            # The spot history will use the most recent prices
        else:
            price, source = get_on_demand_price(
                info.type, instance_region, api_timeout, max_retries,
            )

        render_cost = hours * price
        total_render_cost += render_cost

        # Instance-level cost (launch → job end) — supplementary
        inst_cost = compute_instance_cost(info.launch_time, datetime.now(timezone.utc), price)

        instance_details.append({
            "worker": hostname,
            "instance_id": instance_id,
            "instance_type": info.type,
            "az": info.az,
            "hours": round(hours, 4),
            "rate": round(price, 6),
            "cost": round(render_cost, 2),
            "lifecycle": info.lifecycle,
            "pricing_source": source,
        })

    return {
        "render_cost": round(total_render_cost, 2),
        "total_instance_cost": round(total_instance_cost, 2),
        "total_render_hours": round(total_hours, 4),
        "instance_details": instance_details,
        "pricing_source": instance_details[-1]["pricing_source"] if instance_details else "none",
        "errors": errors,
    }

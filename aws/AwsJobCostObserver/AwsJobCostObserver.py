"""
AwsJobCostObserver.py - Deadline 10 Event Plugin (Monolithic)

Fires on OnJobFinished to compute and record AWS render costs for completed jobs.
All helper modules inlined to avoid import path issues under Python.NET ModuleFromString.
"""

from __future__ import absolute_import, division, print_function

import os
import sys
import json
import csv
import re
import traceback
import subprocess
import threading
from collections import namedtuple, defaultdict
from datetime import datetime, timezone

# AWS
import boto3
from botocore.exceptions import ClientError

# Deadline
from Deadline.Events import DeadlineEventListener
from Deadline.Scripting import RepositoryUtils


# ======================================================================
# Inlined from job_detector.py
# ======================================================================
import re

# -- Known AWS pool/group names ------------------------------------------------
# Verified live on RCS host (2026-06-24):
#   Pools:  none
#   Groups: none, aws-spot, aws-spot-east

AWS_POOLS = frozenset({
    "aws-spot",
    "aws-spot-east",
    "awsportal",
    "aws-portal",
})

AWS_GROUPS = frozenset({
    "aws-spot",
    "aws-spot-east",
    "awsportal",
    "aws-portal",
})

# -- EC2 private DNS hostname patterns -----------------------------------------
# AWS EC2 private DNS: ip-10-0-1-2.us-west-2.compute.internal
# Deadline strips domain: ip-10-0-1-2
# Also matches ip-172-31-x-x (us-east-1 VPC default range)
_EC2_HOSTNAME_RE = re.compile(r"^ip-\d{1,3}-\d{1,3}-\d{1,3}-\d{1,3}$")
# Direct instance ID pattern
_INSTANCE_ID_RE = re.compile(r"^i-[a-f0-9]+$")


def is_aws_job(pool, group, extra_info_2000, worker_hostnames):
    """
    Determine if a job ran on AWS EC2 instances.

    Args:
        pool:               Job pool name (str or None)
        group:              Job group name (str or None)
        extra_info_2000:    ExtraInfo2000 value (str or None)
        worker_hostnames:   List of worker hostnames that rendered this job

    Returns:
        tuple: (is_aws: bool, detection_method: str, reason: str)

    Detection runs in priority order -- first match wins.
    Runs in <100ms (no network calls).
    """
    pool = (pool or "").strip().lower()
    group = (group or "").strip().lower()
    ei2000 = (extra_info_2000 or "").strip()

    # Method 1: Pool name
    if pool and pool in AWS_POOLS:
        return True, "pool", "Pool '%s' is a known AWS pool" % pool

    # Method 2: Group name
    if group and group in AWS_GROUPS:
        return True, "group", "Group '%s' is a known AWS group" % group

    # Method 3: ExtraInfo2000 contains "Portal"
    if ei2000 and "portal" in ei2000.lower():
        return True, "extrainfo", "ExtraInfo2000 contains Portal flag: '%s'" % ei2000

    # Method 4: Worker hostname matches EC2 private DNS pattern
    if worker_hostnames:
        for hn in worker_hostnames:
            hn_stripped = (hn or "").strip()
            if _EC2_HOSTNAME_RE.match(hn_stripped):
                return True, "hostname", "Worker hostname '%s' matches EC2 DNS pattern" % hn_stripped
            if _INSTANCE_ID_RE.match(hn_stripped):
                return True, "instance_id", "Worker hostname '%s' is an EC2 instance ID" % hn_stripped

    return False, "none", "No AWS indicators found"


def get_aws_workers(worker_hostnames):
    """
    Filter worker hostnames to only those matching AWS patterns.

    Returns:
        list of (hostname, is_ec2) tuples
    """
    result = []
    for hn in (worker_hostnames or []):
        hn_stripped = (hn or "").strip()
        is_ec2 = bool(_EC2_HOSTNAME_RE.match(hn_stripped) or
                      _INSTANCE_ID_RE.match(hn_stripped))
        result.append((hn_stripped, is_ec2))
    return result


# ======================================================================
# Inlined from cost_helpers.py
# ======================================================================
import json
import re
import threading
from collections import namedtuple
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

# -- Named tuple for instance metadata -----------------------------------------

InstanceInfo = namedtuple(
    "InstanceInfo",
    ["instance_id", "type", "az", "lifecycle", "launch_time"],
)


# -- Timeout wrapper -----------------------------------------------------------

def call_with_timeout(fn, timeout, *args, **kwargs):
    """
    Run an AWS API call in a daemon thread with a hard timeout.

    If the thread doesn't complete in *timeout* seconds, raises TimeoutError.
    If the function raises, re-raises the original exception.
    """
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
        raise TimeoutError("API call exceeded %ds timeout" % timeout)
    if exc[0]:
        raise exc[0]
    return result[0]


# -- Pricing functions ---------------------------------------------------------

# In-process cache for on-demand prices (avoids repeated GetProducts calls).
# Keyed by (instance_type, region). TTL is effectively the plugin process lifetime.
_OD_PRICE_CACHE = {}


def get_on_demand_price(instance_type, region, api_timeout=30, max_retries=2):
    """
    Query AWS Price List API (pricing:GetProducts) for the on-demand hourly rate.

    Returns: (price: float, source: str)
    Always returns ("on_demand", ...) as the source string.
    """
    cache_key = (instance_type, region)
    if cache_key in _OD_PRICE_CACHE:
        return _OD_PRICE_CACHE[cache_key], "on_demand"

    def _fetch():
        client = boto3.client("pricing", region_name="us-east-1")  # Pricing API is us-east-1 only
        resp = client.get_products(
            ServiceCode="AmazonEC2",
            Filters=[
                {"Type": "TERM_MATCH", "Field": "instanceType", "Value": instance_type},
                {"Type": "TERM_MATCH", "Field": "location",
                 "Value": _region_to_location(region)},
                {"Type": "TERM_MATCH", "Field": "operatingSystem", "Value": "Linux"},
                {"Type": "TERM_MATCH", "Field": "capacitystatus", "Value": "Used"},
                {"Type": "TERM_MATCH", "Field": "tenancy", "Value": "Shared"},
                {"Type": "TERM_MATCH", "Field": "preinstalledSw", "Value": "NA"},
            ],
            MaxResults=1,
        )
        price_list = resp.get("PriceList", [])
        if not price_list:
            return None
        entry = json.loads(price_list[0])
        terms = entry.get("terms", {}).get("OnDemand", {})
        for _tid, term in terms.items():
            dims = term.get("priceDimensions", {})
            for _did, dim in dims.items():
                price = dim.get("pricePerUnit", {}).get("USD")
                if price:
                    return float(price)
        return None

    price = _retry_call(_fetch, api_timeout, max_retries, instance_type, "on_demand")
    if price is not None:
        _OD_PRICE_CACHE[cache_key] = price
        return price, "on_demand"

    # Total fallback: use a hardcoded emergency rate to avoid $0
    return 0.0, "on_demand_unavailable"


def get_avg_spot_price(instance_type, az, start_time, end_time,
                       region, api_timeout=30, max_retries=2):
    """
    Query DescribeSpotPriceHistory for the average spot price during a time window.

    Returns: (price: float, source: str)
    Source is "spot", or "on_demand_fallback" if no history available.
    """
    def _fetch():
        client = boto3.client("ec2", region_name=region)
        kwargs = dict(
            InstanceTypes=[instance_type],
            ProductDescriptions=["Linux/UNIX"],
            StartTime=start_time,
            EndTime=end_time,
        )
        if az:
            kwargs["Filters"] = [{"Name": "availability-zone", "Values": [az]}]
        resp = client.describe_spot_price_history(**kwargs)
        prices = [float(h["SpotPrice"]) for h in resp.get("SpotPriceHistory", []) if h.get("SpotPrice")]
        if not prices:
            # Retry without AZ filter
            kwargs.pop("Filters", None)
            resp = client.describe_spot_price_history(**kwargs)
            prices = [float(h["SpotPrice"]) for h in resp.get("SpotPriceHistory", []) if h.get("SpotPrice")]
        if prices:
            return sum(prices) / len(prices)
        return None

    avg = _retry_call(_fetch, api_timeout, max_retries, instance_type, "spot")
    if avg is not None:
        return avg, "spot"

    # Fallback to on-demand if no spot history
    od_price, _ = get_on_demand_price(instance_type, region, api_timeout, max_retries)
    return od_price, "on_demand_fallback"


# -- Instance metadata ---------------------------------------------------------

def get_instance_info(instance_id, region, api_timeout=30, max_retries=2):
    """
    Fetch instance metadata via describe-instances.

    Returns: InstanceInfo(instance_id, type, az, lifecycle, launch_time)
    lifecycle is "spot" or "on-demand" (derived from InstanceLifecycle field).
    """
    def _fetch():
        client = boto3.client("ec2", region_name=region)
        resp = client.describe_instances(InstanceIds=[instance_id])
        for res in resp.get("Reservations", []):
            for inst in res.get("Instances", []):
                return InstanceInfo(
                    instance_id=instance_id,
                    type=inst["InstanceType"],
                    az=inst.get("Placement", {}).get("AvailabilityZone", ""),
                    lifecycle=inst.get("InstanceLifecycle", "on-demand"),
                    launch_time=inst.get("LaunchTime"),
                )
        raise ValueError("Instance %s not found" % instance_id)

    return _retry_call(_fetch, api_timeout, max_retries, instance_id, "describe-instances")


def get_instances_batch(instance_ids, region, api_timeout=30, max_retries=2):
    """
    Batch describe-instances for multiple IDs (more efficient than one-at-a-time).

    Returns: dict {instance_id: InstanceInfo}
    """
    def _fetch():
        client = boto3.client("ec2", region_name=region)
        resp = client.describe_instances(InstanceIds=list(instance_ids))
        result = {}
        for res in resp.get("Reservations", []):
            for inst in res.get("Instances", []):
                iid = inst["InstanceId"]
                result[iid] = InstanceInfo(
                    instance_id=iid,
                    type=inst["InstanceType"],
                    az=inst.get("Placement", {}).get("AvailabilityZone", ""),
                    lifecycle=inst.get("InstanceLifecycle", "on-demand"),
                    launch_time=inst.get("LaunchTime"),
                )
        return result

    return _retry_call(_fetch, api_timeout, max_retries, ", ".join(instance_ids), "describe-instances-batch")


# -- Hostname ? instance ID resolution -----------------------------------------

def build_hostname_map(worker_hostnames, region, api_timeout=30, max_retries=2):
    """
    Resolve Deadline worker hostnames to EC2 instance IDs.

    Two paths per hostname:
    1. If hostname is already an instance ID (i-xxxxx): use directly.
    2. Else: describe-instances --filter private-dns-name=<hostname>

    Returns: (dict[hostname ? instance_id], set of all resolved instance_ids)
    """
    direct_ids = []
    needs_lookup = []

    for hn in worker_hostnames:
        if not hn:
            continue
        if re.match(r"^i-[a-f0-9]+$", hn):
            direct_ids.append(hn)
        else:
            needs_lookup.append(hn)

    hostname_map = {}
    all_ids = set()

    # Direct IDs map to themselves
    for iid in direct_ids:
        hostname_map[iid] = iid
        all_ids.add(iid)

    # Resolve hostnames via describe-instances
    if needs_lookup:
        def _fetch():
            client = boto3.client("ec2", region_name=region)
            resp = client.describe_instances(
                Filters=[
                    {"Name": "private-dns-name", "Values": needs_lookup},
                    {"Name": "instance-state-name",
                     "Values": ["running", "stopped", "terminated"]},
                ]
            )
            mapping = {}
            for res in resp.get("Reservations", []):
                for inst in res.get("Instances", []):
                    dns = inst.get("PrivateDnsName", "").split(".")[0]
                    iid = inst["InstanceId"]
                    # Match by stripped hostname (Deadline strips domain)
                    for hn in needs_lookup:
                        if dns == hn or dns.startswith(hn) or hn.startswith(dns):
                            mapping[hn] = iid
                            break
                    # Also try private IP match (ip-10-0-1-2 ? 10.0.1.2)
                    priv_ip = inst.get("PrivateIpAddress", "")
                    if priv_ip:
                        ip_hn = "ip-" + priv_ip.replace(".", "-")
                        mapping[ip_hn] = iid
            return mapping

        try:
            resolved = call_with_timeout(_fetch, api_timeout)
            hostname_map.update(resolved)
            all_ids.update(resolved.values())
        except Exception:
            # Best-effort resolution; continue with what we have
            pass

    return hostname_map, all_ids


# -- Instance cost (launch ? end) ----------------------------------------------

def compute_instance_cost(launch_time, end_time, price_per_hr):
    """
    Total instance cost from launch to job end (includes boot, health-check, etc.).
    This is supplementary; render_cost is the authoritative metric.
    """
    if not launch_time or not end_time:
        return 0.0
    # Handle both datetime objects and ISO strings
    if isinstance(launch_time, str):
        launch_time = datetime.fromisoformat(launch_time.replace("Z", "+00:00"))
    if isinstance(end_time, str):
        end_time = datetime.fromisoformat(end_time.replace("Z", "+00:00"))
    # Make both timezone-aware for comparison
    if launch_time.tzinfo is None:
        launch_time = launch_time.replace(tzinfo=timezone.utc)
    if end_time.tzinfo is None:
        end_time = end_time.replace(tzinfo=timezone.utc)
    hours = (end_time - launch_time).total_seconds() / 3600.0
    if hours < 0:
        return 0.0
    return hours * price_per_hr


# -- Region helpers ------------------------------------------------------------

def az_to_region(az):
    """'us-west-2a' ? 'us-west-2'. Strips the trailing letter."""
    return az[:-1] if az and len(az) > 1 else az


_REGION_TO_LOCATION = {
    "us-east-1": "US East (N. Virginia)",
    "us-east-2": "US East (Ohio)",
    "us-west-1": "US West (N. California)",
    "us-west-2": "US West (Oregon)",
    "eu-west-1": "EU (Ireland)",
    "eu-central-1": "EU (Frankfurt)",
    "ap-northeast-1": "Asia Pacific (Tokyo)",
    "ap-southeast-1": "Asia Pacific (Singapore)",
    "ap-south-1": "Asia Pacific (Mumbai)",
}


def _region_to_location(region):
    return _REGION_TO_LOCATION.get(region, "US West (Oregon)")


# -- Alerting ------------------------------------------------------------------

def send_alert(job_id, job_name, submitted_by, cost, threshold,
               webhook_url=None, log_func=None):
    """
    Send a cost threshold alert.

    Tries webhook first (if configured), falls back to logging.
    Uses Deadline's self.LogWarning via log_func callback.
    """
    msg = ("[AwsJobCostObserver] Job '%s' (%s) submitted by '%s' "
           "cost $%.2f exceeds threshold $%.2f" %
           (job_name, job_id, submitted_by, cost, threshold))

    if webhook_url:
        try:
            import requests
            resp = requests.post(
                webhook_url,
                json={
                    "text": msg,
                    "job_id": job_id,
                    "job_name": job_name,
                    "submitted_by": submitted_by,
                    "cost": cost,
                    "threshold": threshold,
                },
                timeout=10,
            )
            if log_func:
                log_func("Alert sent to webhook (HTTP %d)" % resp.status_code)
            return
        except Exception as e:
            if log_func:
                log_func("Webhook alert failed: %s -- falling back to log" % str(e))

    if log_func:
        log_func(msg)


# -- Internal retry helper -----------------------------------------------------

def _retry_call(fn, api_timeout, max_retries, label, api_name):
    """
    Call fn with timeout, retry with exponential backoff.
    Returns fn's result or None on total failure.
    """
    import time
    last_exc = None
    for attempt in range(max_retries + 1):
        try:
            return call_with_timeout(fn, api_timeout)
        except TimeoutError:
            last_exc = "timeout"
            if attempt < max_retries:
                time.sleep(2 ** attempt)
        except ClientError as e:
            last_exc = str(e)
            if attempt < max_retries:
                time.sleep(2 ** attempt)
        except Exception as e:
            last_exc = str(e)
            if attempt < max_retries:
                time.sleep(2 ** attempt)
    # All retries exhausted
    return None


# ======================================================================
# Inlined from cost_compute.py
# ======================================================================
from collections import defaultdict
from datetime import datetime, timezone


# -- Expense categories --------------------------------------------------------

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
            render_cost:        float -- total cost of render hours
            total_instance_cost: float -- cost from instance launch to job end
            total_render_hours: float -- sum of all worker render hours
            instance_details:   list of per-instance dicts
            pricing_source:     str -- "on_demand", "spot", "on_demand_fallback"
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

        # Instance-level cost (launch ? job end) -- supplementary
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


# ======================================================================
# Inlined from cost_report.py
# ======================================================================
import csv
import json
import os
from datetime import datetime, timezone

# -- Output paths --------------------------------------------------------------

DEFAULT_REPORT_DIR = r"C:\DeadlineRepository10\reports\job_cost_reports"
CSV_FILENAME = "cost_log.csv"
JSONL_FILENAME = "cost_observer.jsonl"

# -- CSV schema (24 columns) ---------------------------------------------------

CSV_COLUMNS = [
    # Identity
    "job_id",                    # 1
    "job_name",                  # 2
    "submitted_by",              # 3
    "submitted_at",              # 4
    "completed_at",              # 5
    # Cost metrics
    "render_cost",               # 6
    "total_instance_cost",       # 7
    "total_render_hours",        # 8
    # Instance details
    "instance_count",            # 9
    "instance_type",             # 10
    "instance_ids",              # 11
    "lifecycle",                 # 12  (spot / on-demand / mixed)
    # Pricing
    "pricing_source",            # 13
    "region",                    # 14
    "hourly_rate",               # 15
    # Classification
    "expense_category",          # 16
    "cost_allocation_tag",       # 17
    # Detection
    "detection_method",          # 18
    "pool",                      # 19
    "group",                     # 20
    # Metadata
    "phase",                     # 21  (estimate / reconciled)
    "plugin_version",            # 22
    "computed_at",               # 23
    "notes",                     # 24
]


def ensure_report_dir(report_dir=None):
    """Create report directory if it doesn't exist."""
    path = report_dir or DEFAULT_REPORT_DIR
    os.makedirs(path, exist_ok=True)
    return path


def write_csv_row(cost_data, report_dir=None):
    """
    Append a row to the cost log CSV.

    Creates the file with headers if it doesn't exist.
    Uses Windows-safe line endings.
    """
    path = ensure_report_dir(report_dir)
    csv_path = os.path.join(path, CSV_FILENAME)

    file_exists = os.path.isfile(csv_path)

    row = {col: cost_data.get(col, "") for col in CSV_COLUMNS}

    with open(csv_path, "a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_COLUMNS, extrasaction="ignore")
        if not file_exists:
            writer.writeheader()
        writer.writerow(row)

    return csv_path


def write_jsonl_entry(cost_data, report_dir=None):
    """
    Append a JSONL entry for structured consumption.

    Each line is a complete JSON object.
    """
    path = ensure_report_dir(report_dir)
    jsonl_path = os.path.join(path, JSONL_FILENAME)

    entry = {k: v for k, v in cost_data.items() if k in CSV_COLUMNS or k == "instance_details"}
    entry["_written_at"] = datetime.now(timezone.utc).isoformat()

    with open(jsonl_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, default=str) + "\n")

    return jsonl_path


def build_extrainfo_1980(cost_data):
    """
    Build the ExtraInfo1980 estimate JSON.

    This is the structured cost estimate written to the Deadline job.
    """
    estimate = {
        "version": 1,
        "phase": "estimate",
        "render_cost": cost_data.get("render_cost", 0.0),
        "total_instance_cost": cost_data.get("total_instance_cost", 0.0),
        "total_render_hours": cost_data.get("total_render_hours", 0.0),
        "instance_count": cost_data.get("instance_count", 0),
        "instance_type": cost_data.get("instance_type", "unknown"),
        "pricing_source": cost_data.get("pricing_source", "none"),
        "region": cost_data.get("region", ""),
        "currency": "USD",
        "computed_at": datetime.now(timezone.utc).isoformat(),
        "expense_category": cost_data.get("expense_category", "render-compute"),
        "cost_allocation_tag": cost_data.get("cost_allocation_tag", "houdini-aws-portal"),
    }
    return json.dumps(estimate)


def build_extrainfo_1981(cost_data):
    """
    Build the ExtraInfo1981 human-readable summary.

    Format: $X.XX (estimate) | Nx type | Yh | category | source: Z
    """
    return "%.2f (estimate) | %dx %s | %.1fh | %s | source: %s" % (
        cost_data.get("render_cost", 0.0),
        cost_data.get("instance_count", 0),
        cost_data.get("instance_type", "unknown"),
        cost_data.get("total_render_hours", 0.0),
        cost_data.get("expense_category", "render-compute"),
        cost_data.get("pricing_source", "none"),
    )


def build_extrainfo_1982(reconciled_data):
    """
    Build the ExtraInfo1982 reconciled cost JSON (Phase 2).
    """
    recon = {
        "version": 1,
        "phase": "reconciled",
        "render_cost": reconciled_data.get("render_cost", 0.0),
        "estimate_cost": reconciled_data.get("estimate_cost", 0.0),
        "variance": reconciled_data.get("variance", 0.0),
        "variance_reason": reconciled_data.get("variance_reason", ""),
        "reconciliation_date": datetime.now(timezone.utc).isoformat(),
        "cur_line_items": reconciled_data.get("cur_line_items", 0),
        "expense_category": reconciled_data.get("expense_category", "render-compute"),
    }
    return json.dumps(recon)

PLUGIN_VERSION = "1.0.0"

# Module-level plugin factory (Deadline 10 pattern)


def GetDeadlineEventListener():
    return AwsJobCostObserverEventListener()


def CleanupDeadlineEventListener(eventListener):
    eventListener.Cleanup()


# Event Listener Class


class AwsJobCostObserverEventListener(DeadlineEventListener):
    """Listens for OnJobFinished events and computes AWS render costs."""

    def __init__(self):
        super(AwsJobCostObserverEventListener, self).__init__()
        self.OnJobFinishedCallback += self.OnJobFinished
        self._config_loaded = False

    def Cleanup(self):
        """Deregister callbacks."""
        del self.OnJobFinishedCallback
        self.LogInfo("AwsJobCostObserver cleanup complete")

    # Main callback

    def _load_config(self):
        """Lazy-load config. Called on first OnJobFinished, not in __init__."""
        if self._config_loaded:
            return
        self.default_region = self.GetConfigEntryWithDefault("Region", "us-west-2")
        self.api_timeout = int(self.GetConfigEntryWithDefault("APITimeout", "30"))
        self.max_retries = int(self.GetConfigEntryWithDefault("MaxRetries", "2"))
        self.alert_threshold = float(
            self.GetConfigEntryWithDefault("AlertThreshold", "100.0")
        )
        self.dl_command = self.GetConfigEntryWithDefault(
            "DeadlineCommandPath",
            r"C:\\Program Files\\Thinkbox\\Deadline10\\bin\\deadlinecommand.exe",
        )
        self.webhook_url = self.GetConfigEntryWithDefault(
            "WebhookURL", "http://192.168.90.104:8644/webhook"
        )
        self._config_loaded = True
        self.LogInfo("AwsJobCostObserver v%s initialized" % PLUGIN_VERSION)

    def OnJobFinished(self, job):
        self._load_config()
        """
        Called by Deadline when any job completes.

        Non-blocking: wraps everything in try/except. Any error is logged and
        the plugin exits cleanly without delaying job state transition.
        """
        try:
            self._process_job(job)
        except Exception as e:
            self.LogError(
                "AwsJobCostObserver failed for job %s: %s\n%s"
                % (str(getattr(job, "JobId", "unknown")), str(e), traceback.format_exc())
            )

    # -- Core processing ---------------------------------------------------

    def _process_job(self, job):
        """Process a completed job: detect AWS, compute costs, write reports."""
        job_id = str(job.JobId)
        job_name = job.Name if hasattr(job, "Name") else "unknown"
        pool = job.Pool if hasattr(job, "Pool") else ""
        group = job.Group if hasattr(job, "Group") else ""
        username = job.UserName if hasattr(job, "UserName") else ""
        submitted_dt = str(job.SubmittedDateTime) if hasattr(job, "SubmittedDateTime") else ""

        # Get ExtraInfo2000 for AWS flag detection
        extra_info_2000 = ""
        try:
            extra_info_2000 = job.ExtraInfo2000 if hasattr(job, "ExtraInfo2000") else ""
        except Exception:
            pass

        self.LogInfo("Processing job %s ('%s') by user '%s'" % (job_id, job_name, username))

        # -- Step 1: Detect AWS job ----------------------------------------
        worker_hostnames = self._get_worker_hostnames(job_id)

        aws_detected, method, reason = is_aws_job(
            pool, group, extra_info_2000, worker_hostnames
        )

        if not aws_detected:
            self.LogInfo("Job %s is not an AWS job (%s). Skipping." % (job_id, reason))
            return

        self.LogInfo("Job %s detected as AWS (method=%s): %s" % (job_id, method, reason))

        # -- Step 2: Get task reports for render hours ---------------------
        task_reports = self._get_task_reports(job_id)
        if not task_reports:
            self.LogWarning("No task reports for job %s. Cost will be 0." % job_id)

        worker_hours = compute_render_hours(task_reports)
        self.LogInfo("Render hours: %s" % json.dumps(worker_hours, default=str))

        # -- Step 3: Resolve worker hostnames - instance IDs ---------------
        hostname_map, all_instance_ids = build_hostname_map(
            list(worker_hours.keys()), self.default_region, self.api_timeout, self.max_retries
        )

        instance_infos = {}
        if all_instance_ids:
            try:
                instance_infos = get_instances_batch(
                    list(all_instance_ids), self.default_region, self.api_timeout, self.max_retries
                )
            except Exception as e:
                self.LogWarning("Failed to fetch instance metadata: %s" % str(e))

        # -- Step 4: Compute cost ------------------------------------------
        cost_result = compute_job_cost(
            worker_hostnames=list(worker_hours.keys()),
            worker_hours=worker_hours,
            region=self.default_region,
            hostname_map=hostname_map,
            instance_infos=instance_infos,
            api_timeout=self.api_timeout,
            max_retries=self.max_retries,
        )

        # -- Step 5: Classify expense --------------------------------------
        expense_category = categorize_job(job_name, group, pool)

        # -- Step 6: Build report data -------------------------------------
        instance_types = set()
        instance_ids_list = []
        lifecycles = set()
        hourly_rates = []

        for detail in cost_result.get("instance_details", []):
            if detail.get("instance_type"):
                instance_types.add(detail["instance_type"])
            if detail.get("instance_id"):
                instance_ids_list.append(detail["instance_id"])
            if detail.get("lifecycle"):
                lifecycles.add(detail["lifecycle"])
            if detail.get("rate"):
                hourly_rates.append(detail["rate"])

        report_data = {
            "job_id": job_id,
            "job_name": job_name,
            "submitted_by": username,
            "submitted_at": submitted_dt,
            "completed_at": datetime.now(timezone.utc).isoformat(),
            "render_cost": cost_result["render_cost"],
            "total_instance_cost": cost_result["total_instance_cost"],
            "total_render_hours": cost_result["total_render_hours"],
            "instance_count": len(instance_ids_list),
            "instance_type": "/".join(sorted(instance_types)) if instance_types else "unknown",
            "instance_ids": ",".join(instance_ids_list),
            "lifecycle": "/".join(sorted(lifecycles)) if lifecycles else "unknown",
            "pricing_source": cost_result["pricing_source"],
            "region": self.default_region,
            "hourly_rate": sum(hourly_rates) / len(hourly_rates) if hourly_rates else 0.0,
            "expense_category": expense_category,
            "cost_allocation_tag": "houdini-aws-portal",
            "detection_method": method,
            "pool": pool,
            "group": group,
            "phase": "estimate",
            "plugin_version": PLUGIN_VERSION,
            "computed_at": datetime.now(timezone.utc).isoformat(),
            "notes": "; ".join(cost_result.get("errors", [])),
        }

        # -- Step 7: Write reports -----------------------------------------
        try:
            csv_path = write_csv_row(report_data)
            self.LogInfo("CSV written: %s" % csv_path)
        except Exception as e:
            self.LogError("Failed to write CSV: %s" % str(e))

        try:
            jsonl_path = write_jsonl_entry(report_data)
            self.LogInfo("JSONL written: %s" % jsonl_path)
        except Exception as e:
            self.LogError("Failed to write JSONL: %s" % str(e))

        # -- Step 8: Write ExtraInfo ---------------------------------------
        ei1980 = build_extrainfo_1980(report_data)
        ei1981 = build_extrainfo_1981(report_data)

        self._set_extrainfo(job_id, 1980, ei1980)
        self._set_extrainfo(job_id, 1981, ei1981)

        self.LogInfo("ExtraInfo1980 = %s" % ei1980)
        self.LogInfo("ExtraInfo1981 = %s" % ei1981)

        # -- Step 9: Alert if threshold exceeded ---------------------------
        render_cost = cost_result["render_cost"]
        if render_cost > self.alert_threshold:
            self._send_cost_alert(job_id, job_name, username, render_cost, self.alert_threshold)

        self.LogInfo(
            "Job %s cost: $%.2f (%s, %d instances, %.1fh)"
            % (
                job_id,
                render_cost,
                cost_result["pricing_source"],
                len(instance_ids_list),
                cost_result["total_render_hours"],
            )
        )

    # -- Deadline API helpers ----------------------------------------------

    def _get_worker_hostnames(self, job_id):
        """Get list of worker hostnames that rendered this job."""
        try:
            job_reports = RepositoryUtils.GetJobReports(job_id)
            hostnames = []
            for report in job_reports:
                hn = report.SlaveName if hasattr(report, "SlaveName") else str(report)
                if hn and hn not in hostnames:
                    hostnames.append(hn)
            return hostnames
        except Exception as e:
            self.LogWarning("GetJobReports failed: %s" % str(e))
            return []

    def _get_task_reports(self, job_id):
        """Get task-level reports with StartTime/EndTime per worker."""
        try:
            tasks = RepositoryUtils.GetJobTasks(job_id, True)
            reports = []
            for task in tasks:
                reports.append(
                    {
                        "SlaveName": task.SlaveName if hasattr(task, "SlaveName") else "",
                        "TaskName": task.TaskName if hasattr(task, "TaskName") else "",
                        "StartTime": task.StartTime if hasattr(task, "StartTime") else None,
                        "EndTime": task.EndTime if hasattr(task, "EndTime") else None,
                        "Seconds": task.RenderTime if hasattr(task, "RenderTime") else 0,
                    }
                )
            return reports
        except Exception as e:
            self.LogWarning("GetJobTasks failed: %s" % str(e))
            return []

    def _set_extrainfo(self, job_id, index, value):
        """Set an ExtraInfo value on the job via deadlinecommand."""
        try:
            subprocess.call(
                [self.dl_command, "-SetJobExtraInfoKeyValue", job_id, str(index), value],
                timeout=30,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception as e:
            self.LogWarning("Failed to set ExtraInfo%d on job %s: %s" % (index, job_id, str(e)))

    # -- Alerting ----------------------------------------------------------

    def _send_cost_alert(self, job_id, job_name, username, cost, threshold):
        """Send a cost threshold alert via Hermes webhook."""
        msg = (
            "[AwsJobCostObserver] Job '%s' (%s) by '%s' cost $%.2f exceeds threshold $%.2f"
            % (job_name, job_id, username, cost, threshold)
        )
        try:
            payload = json.dumps(
                {
                    "text": msg,
                    "job_id": job_id,
                    "job_name": job_name,
                    "cost": cost,
                    "threshold": threshold,
                }
            )
            subprocess.call(
                [
                    "curl", "-s", "-X", "POST",
                    "-H", "Content-Type: application/json",
                    "-d", payload,
                    "-m", "10",
                    self.webhook_url,
                ],
                timeout=15,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self.LogInfo("Alert sent to Hermes webhook")
        except Exception as e:
            self.LogWarning("Webhook alert failed: %s" % str(e))
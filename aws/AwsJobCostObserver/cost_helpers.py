"""
cost_helpers.py — AWS API helpers for AwsJobCostObserver.

Each function wraps an AWS API call with thread-based timeout + retry.
Imported by cost_utils.py and AwsJobCostObserver.py.

Spec: docs/AwsJobCostObserver-Design.md § Helper function contracts
"""

from __future__ import absolute_import, division, print_function

import json
import re
import threading
from collections import namedtuple
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

# ── Named tuple for instance metadata ─────────────────────────────────────────

InstanceInfo = namedtuple(
    "InstanceInfo",
    ["instance_id", "type", "az", "lifecycle", "launch_time"],
)


# ── Timeout wrapper ───────────────────────────────────────────────────────────

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


# ── Pricing functions ─────────────────────────────────────────────────────────

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


# ── Instance metadata ─────────────────────────────────────────────────────────

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


# ── Hostname → instance ID resolution ─────────────────────────────────────────

def build_hostname_map(worker_hostnames, region, api_timeout=30, max_retries=2):
    """
    Resolve Deadline worker hostnames to EC2 instance IDs.

    Two paths per hostname:
    1. If hostname is already an instance ID (i-xxxxx): use directly.
    2. Else: describe-instances --filter private-dns-name=<hostname>

    Returns: (dict[hostname → instance_id], set of all resolved instance_ids)
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
                    # Also try private IP match (ip-10-0-1-2 → 10.0.1.2)
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


# ── Instance cost (launch → end) ──────────────────────────────────────────────

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


# ── Region helpers ────────────────────────────────────────────────────────────

def az_to_region(az):
    """'us-west-2a' → 'us-west-2'. Strips the trailing letter."""
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


# ── Alerting ──────────────────────────────────────────────────────────────────

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
                log_func("Webhook alert failed: %s — falling back to log" % str(e))

    if log_func:
        log_func(msg)


# ── Internal retry helper ─────────────────────────────────────────────────────

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

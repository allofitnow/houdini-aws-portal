"""
AwsJobCostObserver.py — Deadline 10 Event Plugin

Fires on OnJobFinished to compute and record AWS render costs for completed jobs.

Non-blocking design:
  - Top-level try/except catches ALL exceptions
  - AWS API calls wrapped in call_with_timeout (30s hard limit)
  - Retries with exponential backoff (2 retries, base delay 2s)
  - Any failure logs error and exits cleanly — never blocks job completion

Detection:
  - 4-method AWS job detection (pool, group, ExtraInfo2000, hostname pattern)
  - Non-AWS jobs (local workers) are skipped silently

Output:
  - CSV log:     C:\\DeadlineRepository10\\reports\\job_cost_reports\\cost_log.csv
  - JSONL log:   C:\\DeadlineRepository10\\reports\\job_cost_reports\\cost_observer.jsonl
  - ExtraInfo1980: cost estimate JSON
  - ExtraInfo1981: human-readable cost summary

Spec: docs/AwsJobCostObserver-Design.md
Issues: #103, #115, #116, #117, #118, #119, #120
"""

from __future__ import absolute_import, division, print_function

import os
import sys
import traceback
from datetime import datetime, timezone

# ── Plugin path setup ─────────────────────────────────────────────────────────
# Deadline event plugins import this file as a module. Ensure local imports work.
_PLUGIN_DIR = os.path.dirname(os.path.abspath(__file__))
if _PLUGIN_DIR not in sys.path:
    sys.path.insert(0, _PLUGIN_DIR)

from job_detector import is_aws_job, get_aws_workers
from cost_helpers import build_hostname_map, get_instances_batch
from cost_compute import compute_render_hours, compute_job_cost, categorize_job
from cost_report import (
    write_csv_row,
    write_jsonl_entry,
    build_extrainfo_1980,
    build_extrainfo_1981,
)

# ── Constants ─────────────────────────────────────────────────────────────────

PLUGIN_VERSION = "1.0.0"
DEFAULT_REGION = os.environ.get("AWS_REGION", "us-west-2")
API_TIMEOUT = 30          # seconds per AWS API call
MAX_RETRIES = 2           # retry attempts after initial call
ALERT_THRESHOLD = float(os.environ.get("AWS_COST_ALERT_THRESHOLD", "100.0"))

# ── Deadline Event Plugin Interface ──────────────────────────────────────────


def GetResolvedEventListenerNames():
    """Register for the events we want to handle."""
    return ("OnJobFinished",)


def OnJobFinished(jobId, extraDirectory, job, username):
    """
    Main entry point — called by Deadline when a job completes.

    Non-blocking: wraps everything in try/except. Any error is logged and
    the plugin exits cleanly without delaying job state transition.
    """
    try:
        _process_job(jobId, job, username)
    except Exception as e:
        _log_error("AwsJobCostObserver failed for job %s: %s\n%s" %
                   (jobId, str(e), traceback.format_exc()))
    # Always return None — never block job completion


# ── Core processing ──────────────────────────────────────────────────────────


def _process_job(jobId, job, username):
    """
    Process a completed job: detect AWS, compute costs, write reports.
    """
    job_name = job.get("Name", "unknown")
    pool = job.get("Pool", "")
    group = job.get("Group", "")
    extra_info_2000 = job.get("ExtraInfo2000", "")

    _log_info("Processing job %s ('%s') by user '%s'" % (jobId, job_name, username))

    # ── Step 1: Detect AWS job ────────────────────────────────────────────────
    worker_hostnames = _get_worker_hostnames(jobId)

    aws_detected, method, reason = is_aws_job(pool, group, extra_info_2000, worker_hostnames)

    if not aws_detected:
        _log_info("Job %s is not an AWS job (%s). Skipping." % (jobId, reason))
        return

    _log_info("Job %s detected as AWS (method=%s): %s" % (jobId, method, reason))

    # ── Step 2: Get task reports for render hours ─────────────────────────────
    task_reports = _get_task_reports(jobId)
    if not task_reports:
        _log_warn("No task reports for job %s. Cost will be 0." % jobId)

    worker_hours = compute_render_hours(task_reports)
    _log_info("Render hours: %s" % json.dumps(worker_hours, default=str))

    # ── Step 3: Resolve worker hostnames → instance IDs ──────────────────────
    hostname_map, all_instance_ids = build_hostname_map(
        list(worker_hours.keys()), DEFAULT_REGION, API_TIMEOUT, MAX_RETRIES
    )

    # Fetch instance metadata in batch
    instance_infos = {}
    if all_instance_ids:
        try:
            instance_infos = get_instances_batch(
                list(all_instance_ids), DEFAULT_REGION, API_TIMEOUT, MAX_RETRIES
            )
        except Exception as e:
            _log_warn("Failed to fetch instance metadata: %s" % str(e))

    # ── Step 4: Compute cost ──────────────────────────────────────────────────
    cost_result = compute_job_cost(
        worker_hostnames=list(worker_hours.keys()),
        worker_hours=worker_hours,
        region=DEFAULT_REGION,
        hostname_map=hostname_map,
        instance_infos=instance_infos,
        api_timeout=API_TIMEOUT,
        max_retries=MAX_RETRIES,
    )

    # ── Step 5: Classify expense ─────────────────────────────────────────────
    expense_category = categorize_job(job_name, group, pool)

    # ── Step 6: Build report data ─────────────────────────────────────────────
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
        "job_id": jobId,
        "job_name": job_name,
        "submitted_by": username or job.get("UserName", ""),
        "submitted_at": job.get("SubmittedDateTime", ""),
        "completed_at": datetime.now(timezone.utc).isoformat(),
        "render_cost": cost_result["render_cost"],
        "total_instance_cost": cost_result["total_instance_cost"],
        "total_render_hours": cost_result["total_render_hours"],
        "instance_count": len(instance_ids_list),
        "instance_type": "/".join(sorted(instance_types)) if instance_types else "unknown",
        "instance_ids": ",".join(instance_ids_list),
        "lifecycle": "/".join(sorted(lifecycles)) if lifecycles else "unknown",
        "pricing_source": cost_result["pricing_source"],
        "region": DEFAULT_REGION,
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

    # ── Step 7: Write reports ─────────────────────────────────────────────────
    try:
        csv_path = write_csv_row(report_data)
        _log_info("CSV written: %s" % csv_path)
    except Exception as e:
        _log_error("Failed to write CSV: %s" % str(e))

    try:
        jsonl_path = write_jsonl_entry(report_data)
        _log_info("JSONL written: %s" % jsonl_path)
    except Exception as e:
        _log_error("Failed to write JSONL: %s" % str(e))

    # ── Step 8: Write ExtraInfo ───────────────────────────────────────────────
    ei1980 = build_extrainfo_1980(report_data)
    ei1981 = build_extrainfo_1981(report_data)

    _set_extrainfo(jobId, 1980, ei1980)
    _set_extrainfo(jobId, 1981, ei1981)

    _log_info("ExtraInfo1980 = %s" % ei1980)
    _log_info("ExtraInfo1981 = %s" % ei1981)

    # ── Step 9: Alert if threshold exceeded ──────────────────────────────────
    render_cost = cost_result["render_cost"]
    if render_cost > ALERT_THRESHOLD:
        _send_cost_alert(jobId, job_name, username, render_cost, ALERT_THRESHOLD)

    _log_info("Job %s cost: $%.2f (%s, %d instances, %.1fh)" %
              (jobId, render_cost, cost_result["pricing_source"],
               len(instance_ids_list), cost_result["total_render_hours"]))


# ── Deadline API helpers ─────────────────────────────────────────────────────


def _get_worker_hostnames(jobId):
    """
    Get list of worker hostnames that rendered this job.
    Uses Deadline's Repository API to get task reports.
    """
    try:
        # In Deadline event plugin context, we have access to the Repository API
        # via the global Deadline object
        import Repository
        reports = Repository.GetJobReports(jobId)
        hostnames = []
        for report in reports:
            hn = report.get("SlaveName") or report.get("WorkerName")
            if hn and hn not in hostnames:
                hostnames.append(hn)
        return hostnames
    except Exception:
        # In some contexts, Repository isn't available directly
        # Fall back to job data if available
        return []


def _get_task_reports(jobId):
    """
    Get task-level reports with StartTime/EndTime per worker.
    """
    try:
        import Repository
        taskReports = Repository.GetJobTaskReports(jobId)
        return taskReports
    except Exception:
        return []


def _set_extrainfo(jobId, index, value):
    """Set an ExtraInfo value on the job via deadlinecommand."""
    import subprocess
    try:
        dl = r"C:\Program Files\Thinkbox\Deadline10\bin\deadlinecommand.exe"
        subprocess.call(
            [dl, "-SetJobExtraInfoKeyValue", jobId, str(index), value],
            timeout=30,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception as e:
        _log_warn("Failed to set ExtraInfo%d on job %s: %s" % (index, jobId, str(e)))


# ── Alerting ──────────────────────────────────────────────────────────────────


def _send_cost_alert(job_id, job_name, username, cost, threshold):
    """Send a cost threshold alert via Hermes webhook."""
    import json as _json
    import subprocess

    msg = ("[AwsJobCostObserver] Job '%s' (%s) by '%s' cost $%.2f exceeds threshold $%.2f" %
           (job_name, job_id, username, cost, threshold))

    # Hermes webhook
    webhook_url = os.environ.get(
        "HERMES_WEBHOOK_URL",
        "http://192.168.90.104:8644/webhook"
    )
    webhook_secret = os.environ.get("HERMES_WEBHOOK_SECRET", "")

    try:
        payload = _json.dumps({
            "text": msg,
            "job_id": job_id,
            "job_name": job_name,
            "cost": cost,
            "threshold": threshold,
        })

        cmd = [
            "curl", "-s", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", "X-Webhook-Secret: %s" % webhook_secret,
            "-d", payload,
            "-m", "10",
            webhook_url,
        ]
        subprocess.call(cmd, timeout=15,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        _log_info("Alert sent to Hermes webhook")
    except Exception as e:
        _log_warn("Webhook alert failed: %s" % str(e))


# ── Logging ──────────────────────────────────────────────────────────────────

# Deadline event plugins use self.LogInfo/LogWarning/LogError
# In standalone testing context, fall back to print
def _log_info(msg):
    try:
        self.LogInfo(msg)
    except (NameError, AttributeError):
        print("[INFO] %s" % msg)


def _log_warn(msg):
    try:
        self.LogWarning(msg)
    except (NameError, AttributeError):
        print("[WARN] %s" % msg)


def _log_error(msg):
    try:
        self.LogError(msg)
    except (NameError, AttributeError):
        print("[ERROR] %s" % msg)


# Need json import for logging
import json

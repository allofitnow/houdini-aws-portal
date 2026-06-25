"""
AwsJobCostObserver.py - Deadline 10 Event Plugin

Fires on OnJobFinished to compute and record AWS render costs for completed jobs.
"""

from __future__ import absolute_import, division, print_function

import os
import sys
import json
import traceback
import subprocess
from datetime import datetime, timezone

# Plugin path setup
_PLUGIN_DIR = os.path.dirname(os.path.abspath(__file__))
if _PLUGIN_DIR not in sys.path:
    sys.path.insert(0, _PLUGIN_DIR)

# Deadline imports
from Deadline.Events import DeadlineEventListener
from Deadline.Scripting import RepositoryUtils

# Local imports
from job_detector import is_aws_job
from cost_helpers import build_hostname_map, get_instances_batch
from cost_compute import compute_render_hours, compute_job_cost, categorize_job
from cost_report import (
    write_csv_row,
    write_jsonl_entry,
    build_extrainfo_1980,
    build_extrainfo_1981,
)

# Constants
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
        # Register for the OnJobFinished callback
        self.OnJobFinishedCallback += self.OnJobFinished

        # Read config from .param file
        self.default_region = self.GetConfigEntryWithDefault("Region", "us-west-2")
        self.api_timeout = int(self.GetConfigEntryWithDefault("APITimeout", "30"))
        self.max_retries = int(self.GetConfigEntryWithDefault("MaxRetries", "2"))
        self.alert_threshold = float(
            self.GetConfigEntryWithDefault("AlertThreshold", "100.0")
        )
        self.dl_command = self.GetConfigEntryWithDefault(
            "DeadlineCommandPath",
            r"C:\Program Files\Thinkbox\Deadline10\bin\deadlinecommand.exe",
        )
        self.webhook_url = self.GetConfigEntryWithDefault(
            "WebhookURL", "http://192.168.90.104:8644/webhook"
        )

        self.LogInfo("AwsJobCostObserver v%s initialized" % PLUGIN_VERSION)

    def Cleanup(self):
        """Deregister callbacks."""
        del self.OnJobFinishedCallback
        self.LogInfo("AwsJobCostObserver cleanup complete")

    # Main callback

    def OnJobFinished(self, job):
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

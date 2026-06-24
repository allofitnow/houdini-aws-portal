"""
cost_report.py — CSV report writing, JSONL logging, and ExtraInfo management.

Outputs:
  1. CSV at C:\\DeadlineRepository10\\reports\\job_cost_reports\\cost_log.csv
  2. JSONL at C:\\DeadlineRepository10\\reports\\job_cost_reports\\cost_observer.jsonl
  3. ExtraInfo1980 (estimate JSON) and ExtraInfo1981 (human-readable summary)

Spec: docs/AwsJobCostObserver-Design.md § E11.6 — Report output
Issue: #119
"""

from __future__ import absolute_import, division, print_function

import csv
import json
import os
from datetime import datetime, timezone

# ── Output paths ──────────────────────────────────────────────────────────────

DEFAULT_REPORT_DIR = r"C:\DeadlineRepository10\reports\job_cost_reports"
CSV_FILENAME = "cost_log.csv"
JSONL_FILENAME = "cost_observer.jsonl"

# ── CSV schema (24 columns) ───────────────────────────────────────────────────

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

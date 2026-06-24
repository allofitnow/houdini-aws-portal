"""
job_detector.py — AWS job detection logic for AwsJobCostObserver.

Determines whether a completed Deadline job ran on AWS EC2 instances.
Uses 4 detection methods in priority order (no network calls, pure local logic):

  1. Pool name matches known AWS pools
  2. Group name matches known AWS groups
  3. ExtraInfo2000 contains "Portal"
  4. Worker hostname matches EC2 private DNS pattern

Spec: docs/AwsJobCostObserver-Design.md § E11.2 — AWS job detection
Issue: #115
"""

from __future__ import absolute_import, division, print_function

import re

# ── Known AWS pool/group names ────────────────────────────────────────────────
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

# ── EC2 private DNS hostname patterns ─────────────────────────────────────────
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

    Detection runs in priority order — first match wins.
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

#!/usr/bin/env bash
# aws/terminate_spot_worker.sh — Terminate spot worker(s) launched by this project
# Preconditions: instances exist and were tagged with project=deadline-worker
set -euo pipefail

REGION="us-west-2"
TAG_PROJECT="deadline-worker"

# ── Parse args ────────────────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
    echo "Usage:"
    echo "  $0 --list              List running workers"
    echo "  $0 --all               Terminate all project workers"
    echo "  $0 i-abc123 [i-def456] Terminate specific instance(s)"
    exit 0
fi

# ── List mode ─────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--list" ]]; then
    echo "==> Running deadline-worker instances:"
    INSTANCES=$(aws ec2 describe-instances \
        --filters "Name=tag:project,Values=$TAG_PROJECT" \
                   "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --region "$REGION" \
        --query "Reservations[].Instances[].{ID:InstanceId,State:State.Name,IP:PublicIpAddress,LaunchTime:LaunchTime}" \
        --output table 2>/dev/null)

    if [[ -z "$INSTANCES" || "$INSTANCES" == *"None"* ]]; then
        echo "    No workers found."
    else
        echo "$INSTANCES"
    fi
    exit 0
fi

# ── Terminate all ─────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--all" ]]; then
    IDS=$(aws ec2 describe-instances \
        --filters "Name=tag:project,Values=$TAG_PROJECT" \
                   "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --region "$REGION" \
        --query "Reservations[].Instances[].InstanceId" \
        --output text 2>/dev/null || true)

    if [[ -z "$IDS" ]]; then
        echo "==> No workers to terminate."
        exit 0
    fi

    echo "==> Terminating all workers: $IDS"
    # shellcheck disable=SC2086
    aws ec2 terminate-instances \
        --instance-ids $IDS \
        --region "$REGION" \
        --output table
    exit 0
fi

# ── Terminate specific instances ──────────────────────────────────────────────
echo "==> Terminating: $*"
aws ec2 terminate-instances \
    --instance-ids "$@" \
    --region "$REGION" \
    --output table

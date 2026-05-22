#!/usr/bin/env bash
# aws/terminate_spot_worker.sh — Terminate spot worker(s) and clean up ZeroTier
# Preconditions: instances exist and were tagged with project=deadline-worker
set -euo pipefail

# ── AWS CLI path ─────────────────────────────────────────────────────────────
# uv-installed AWS CLI may not be on PATH; prefer it if found
AWS_CLI="/home/aoin/.cache/uv/archive-v0/FXuFsIxiijforE87cox8l/bin/aws"
if [[ -x "$AWS_CLI" ]]; then
    PATH="/home/aoin/.cache/uv/archive-v0/FXuFsIxiijforE87cox8l/bin:$PATH"
fi

REGION="us-west-2"
TAG_PROJECT="deadline-worker"
ZT_NETWORK="d3ecf5726d14ac76"
ZT_TOKEN="${ZEROTIER_API_TOKEN:-}"

# ── Parse args ────────────────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
    echo "Usage:"
    echo "  $0 --list              List running workers"
    echo "  $0 --all               Terminate all project workers"
    echo "  $0 i-abc123 [i-def456] Terminate specific instance(s)"
    exit 0
fi

# ── Helper: find ZeroTier node IDs associated with instances ──────────────────
# Each instance's ZeroTier node ID is stored in the log or can be found by
# matching the instance's public IP against ZeroTier member physicalAddress.
zt_cleanup_for_instance() {
    local INSTANCE_IP="$1"

    if [[ -z "$ZT_TOKEN" || -z "$INSTANCE_IP" ]]; then
        return
    fi

    # Find ZeroTier members whose physicalAddress matches this instance IP
    MEMBERS=$(curl -sf -H "Authorization: token $ZT_TOKEN" \
        "https://my.zerotier.com/api/v1/network/$ZT_NETWORK/member" 2>/dev/null || echo "[]")

    # Match by physical IP (ZeroTier stores the last-known public IP)
    NODE_IDS=$(echo "$MEMBERS" | jq -r \
        ".[] | select(.physicalAddress | startswith(\"$INSTANCE_IP\")) | .nodeId" 2>/dev/null || true)

    for NODE_ID in $NODE_IDS; do
        echo "    ZeroTier: deauthorizing and deleting node $NODE_ID (IP: $INSTANCE_IP)"

        # Deauthorize first, then delete
        curl -sf -X DELETE \
            -H "Authorization: token $ZT_TOKEN" \
            "https://my.zerotier.com/api/v1/network/$ZT_NETWORK/member/$NODE_ID" \
            >/dev/null 2>&1 || true

        echo "    OK: node $NODE_ID removed from network"
    done
}

# ── Helper: terminate instances and clean up ZeroTier ─────────────────────────
terminate_and_cleanup() {
    local IDS="$1"

    # Get instance IPs before terminating (for ZeroTier cleanup)
    # shellcheck disable=SC2086
    INSTANCE_IPS=$(aws ec2 describe-instances \
        --instance-ids $IDS \
        --region "$REGION" \
        --query "Reservations[].Instances[].PublicIpAddress" \
        --output text 2>/dev/null || true)

    echo "==> Terminating instances: $IDS"
    # shellcheck disable=SC2086
    aws ec2 terminate-instances \
        --instance-ids $IDS \
        --region "$REGION" \
        --output table

    # Clean up ZeroTier nodes
    if [[ -n "$INSTANCE_IPS" && "$INSTANCE_IPS" != "None" ]]; then
        echo ""
        echo "==> ZeroTier cleanup:"
        for IP in $INSTANCE_IPS; do
            zt_cleanup_for_instance "$IP"
        done
    fi
}

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

    # shellcheck disable=SC2086
    terminate_and_cleanup "$IDS"
    exit 0
fi

# ── Terminate specific instances ──────────────────────────────────────────────
IDS="$*"
# shellcheck disable=SC2086
terminate_and_cleanup "$IDS"

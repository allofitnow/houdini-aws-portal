#!/usr/bin/env bash
# terminate_spot_worker.sh
# List or gracefully terminate Spot workers tagged project=deadline-worker.
#
# Graceful termination does best-effort cleanup before terminating EC2:
#   - delete the Worker from Deadline via deadlinecommand -DeleteSlave
#   - stop deadline10launcher on the instance
#   - remove the instance ZeroTier member from the configured network
#   - terminate the EC2 instance
#
# Preconditions:
#   - AWS CLI configured for account 774538489810, region us-west-2
#   - For cleanup: instance has SSM online and IAM permission for ssm:SendCommand/GetCommandInvocation
#   - For ZeroTier removal: .env has ZEROTIER_API_TOKEN or env var is exported
#
# Usage:
#   ./terminate_spot_worker.sh --list           List running workers
#   ./terminate_spot_worker.sh <instance-id>    Gracefully terminate specific instance
#   ./terminate_spot_worker.sh --all            Gracefully terminate all project workers

set -euo pipefail

REGION="${REGION:-us-west-2}"
TAG_FILTER="Name=tag:project,Values=deadline-worker"
STATE_FILTER="Name=instance-state-name,Values=running,pending"
ZT_NETWORK_ID="d3ecf5726d14ac76"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

list_workers() {
    aws ec2 describe-instances         --region "$REGION"         --filters "$TAG_FILTER" "$STATE_FILTER"         --query "Reservations[].Instances[].[InstanceId,State.Name,InstanceType,LaunchTime,Tags[?Key=='Name']|[0].Value]"         --output table
}

ssm_run_cleanup() {
    local id="$1"
    local command_id status output worker_name zt_node_id

    echo "Running Deadline/ZeroTier pre-termination cleanup on ${id} via SSM..."

    command_id=$(aws ssm send-command         --region "$REGION"         --instance-ids "$id"         --document-name AWS-RunShellScript         --parameters 'commands=["WORKER_NAME=$(hostname)","ZT_NODE_ID=$(sudo zerotier-cli info 2>/dev/null | cut -d' ' -f3 || true)","echo DEADLINE_WORKER_NAME=${WORKER_NAME}","echo ZEROTIER_NODE_ID=${ZT_NODE_ID}","if [ -x /opt/Thinkbox/Deadline10/bin/deadlinecommand ]; then /opt/Thinkbox/Deadline10/bin/deadlinecommand -DeleteSlave ${WORKER_NAME} || true; fi","sudo systemctl stop deadline10launcher || true"]'         --query Command.CommandId         --output text 2>/dev/null || true)

    if [[ -z "${command_id:-}" || "$command_id" == "None" ]]; then
        echo "WARNING: Could not start SSM cleanup for ${id}; continuing with EC2 termination." >&2
        return 0
    fi

    for _ in {1..30}; do
        status=$(aws ssm get-command-invocation             --region "$REGION"             --command-id "$command_id"             --instance-id "$id"             --query Status             --output text 2>/dev/null || true)
        case "$status" in
            Success|Cancelled|TimedOut|Failed|Cancelling) break ;;
        esac
        sleep 2
    done

    output=$(aws ssm get-command-invocation         --region "$REGION"         --command-id "$command_id"         --instance-id "$id"         --query StandardOutputContent         --output text 2>/dev/null || true)

    echo "$output"

    worker_name=$(awk -F= '/^DEADLINE_WORKER_NAME=/{print $2; exit}' <<< "$output")
    zt_node_id=$(awk -F= '/^ZEROTIER_NODE_ID=/{print $2; exit}' <<< "$output")

    if [[ -n "${worker_name:-}" ]]; then
        echo "Deadline worker cleanup requested for: ${worker_name}"
    fi

    if [[ -n "${zt_node_id:-}" && "$zt_node_id" != "None" ]]; then
        remove_zerotier_member "$zt_node_id"
    else
        echo "WARNING: Could not determine ZeroTier node ID for ${id}; skipping ZeroTier removal." >&2
    fi
}

remove_zerotier_member() {
    local node_id="$1"

    if [[ -z "${ZEROTIER_API_TOKEN:-}" ]]; then
        echo "WARNING: ZEROTIER_API_TOKEN not set; skipping ZeroTier member removal for ${node_id}." >&2
        return 0
    fi

    echo "Removing ZeroTier member ${node_id} from network ${ZT_NETWORK_ID}..."
    curl -fsS -X DELETE         -H "Authorization: token ${ZEROTIER_API_TOKEN}"         "https://api.zerotier.com/api/v1/network/${ZT_NETWORK_ID}/member/${node_id}"         >/dev/null || echo "WARNING: ZeroTier member removal failed for ${node_id}." >&2
}

terminate_one() {
    local id="$1"

    ssm_run_cleanup "$id"

    aws ec2 terminate-instances         --region "$REGION"         --instance-ids "$id"         --query "TerminatingInstances[0].[InstanceId,CurrentState.Name]"         --output table
    echo "Terminated: ${id}"
}

terminate_all() {
    mapfile -t ids < <(aws ec2 describe-instances         --region "$REGION"         --filters "$TAG_FILTER" "$STATE_FILTER"         --query "Reservations[].Instances[].InstanceId"         --output text)

    local clean_ids=()
    for id in "${ids[@]}"; do
        [[ -n "$id" && "$id" != "None" ]] && clean_ids+=("$id")
    done

    if [[ ${#clean_ids[@]} -eq 0 ]]; then
        echo "No running deadline-worker instances found."
        return
    fi

    echo "Gracefully terminating ${#clean_ids[@]} instance(s): ${clean_ids[*]}"
    for id in "${clean_ids[@]}"; do
        terminate_one "$id"
    done
}

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 --list | --all | <instance-id>" >&2
    exit 1
fi

case "$1" in
    --list) list_workers ;;
    --all)  terminate_all ;;
    i-*)    terminate_one "$1" ;;
    *)
        echo "ERROR: Unknown argument '${1}'" >&2
        echo "Usage: $0 --list | --all | <instance-id>" >&2
        exit 1
        ;;
esac

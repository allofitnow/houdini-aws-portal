#!/usr/bin/env bash
# terminate_spot_worker.sh
# List or gracefully terminate manual workers tagged project=deadline-worker.
#
# Cleanup is best-effort before terminating EC2:
#   - deregister the Worker from Deadline via SSM when available
#   - stop deadline10launcher on the instance
#   - remove matching ZeroTier members from the configured network
#   - terminate EC2 instances in the selected region

set -euo pipefail

REGION="${REGION:-${AWS_REGION:-us-west-2}}"
TAG_PROJECT="${TAG_PROJECT:-deadline-worker}"
ZT_NETWORK="${ZT_NETWORK:-${ZT_NETWORK_ID:-d3ecf5726d14ac76}}"
ZT_TOKEN="${ZEROTIER_API_TOKEN:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
COMMAND=""
INSTANCE_IDS=()

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

usage() {
    cat >&2 <<USAGE
Usage: $0 [--region REGION] --list | --all | <instance-id> [<instance-id> ...]
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region|--aws-region) REGION="$2"; shift 2 ;;
        --list|--all) COMMAND="$1"; shift ;;
        i-*) COMMAND="instances"; INSTANCE_IDS+=("$1"); shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: Unknown argument '$1'" >&2; usage; exit 1 ;;
    esac
done

list_workers() {
    echo "==> Running/stopped deadline-worker instances in ${REGION}:"
    aws ec2 describe-instances \
        --filters "Name=tag:project,Values=$TAG_PROJECT" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --region "$REGION" \
        --query "Reservations[].Instances[].{ID:InstanceId,State:State.Name,IP:PublicIpAddress,LaunchTime:LaunchTime}" \
        --output table 2>/dev/null || echo "    No workers found."
}

remove_zerotier_members_for_ip() {
    local instance_ip="$1"
    local members node_ids node_id

    if [[ -z "$ZT_TOKEN" || -z "$instance_ip" || "$instance_ip" == "None" ]]; then
        return 0
    fi

    members=$(curl -sf -H "Authorization: token $ZT_TOKEN" \
        "https://my.zerotier.com/api/v1/network/$ZT_NETWORK/member" 2>/dev/null || echo "[]")

    node_ids=$(jq -r \
        ".[] | select(.physicalAddress | startswith(\"$instance_ip\")) | .nodeId" \
        <<< "$members" 2>/dev/null || true)

    for node_id in $node_ids; do
        echo "    ZeroTier: deleting node $node_id (public IP: $instance_ip)"
        curl -sf -X DELETE \
            -H "Authorization: token $ZT_TOKEN" \
            "https://my.zerotier.com/api/v1/network/$ZT_NETWORK/member/$node_id" \
            >/dev/null 2>&1 || echo "    WARNING: ZeroTier delete failed for $node_id" >&2
    done
}

deregister_deadline_worker() {
    local instance_id="$1"
    local ssm_status dereg_cmd cmd_id output

    ssm_status=$(aws ssm describe-instance-information \
        --filters "Key=InstanceIds,Values=$instance_id" \
        --region "$REGION" \
        --query 'InstanceInformationList[0].PingStatus' \
        --output text 2>/dev/null || echo "Offline")

    if [[ "$ssm_status" != "Online" ]]; then
        echo "    WARNING: SSM ${ssm_status} for ${instance_id}; skipping Deadline deregistration" >&2
        return 0
    fi

    # shellcheck disable=SC2016
    dereg_cmd=$(printf '%s' 'export PATH="/opt/hfs21.0/bin:/opt/Thinkbox/Deadline10/bin:$PATH"; deadlinecommand -removeWorker 2>&1 || deadlinecommand -DeleteSlave $(hostname) 2>&1 || true; systemctl stop deadline10launcher 2>/dev/null || true' | base64 -w0)
    cmd_id=$(aws ssm send-command \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[\"echo $dereg_cmd | base64 -d | bash\"]" \
        --timeout-seconds 30 \
        --region "$REGION" \
        --query 'Command.CommandId' \
        --output text 2>/dev/null || true)

    if [[ -z "$cmd_id" || "$cmd_id" == "None" ]]; then
        echo "    WARNING: Could not send deregister command to ${instance_id}" >&2
        return 0
    fi

    sleep 8
    output=$(aws ssm get-command-invocation \
        --command-id "$cmd_id" \
        --instance-id "$instance_id" \
        --region "$REGION" \
        --query 'StandardOutputContent' \
        --output text 2>/dev/null || true)
    printf '%s\n' "$output" | sed 's/^/    Deadline: /'
}

terminate_instances() {
    local ids=("$@")
    local instance_ips

    if [[ ${#ids[@]} -eq 0 ]]; then
        echo "No workers to terminate."
        return 0
    fi

    echo "==> Deregistering workers from Deadline in ${REGION}..."
    for id in "${ids[@]}"; do
        deregister_deadline_worker "$id"
    done

    instance_ips=$(aws ec2 describe-instances \
        --instance-ids "${ids[@]}" \
        --region "$REGION" \
        --query "Reservations[].Instances[].PublicIpAddress" \
        --output text 2>/dev/null || true)

    echo ""
    echo "==> Terminating instances in ${REGION}: ${ids[*]}"
    aws ec2 terminate-instances \
        --instance-ids "${ids[@]}" \
        --region "$REGION" \
        --output table

    if [[ -n "$instance_ips" && "$instance_ips" != "None" ]]; then
        echo ""
        echo "==> ZeroTier cleanup:"
        for ip in $instance_ips; do
            remove_zerotier_members_for_ip "$ip"
        done
    fi
}

terminate_all() {
    local ids_text ids=()
    ids_text=$(aws ec2 describe-instances \
        --filters "Name=tag:project,Values=$TAG_PROJECT" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --region "$REGION" \
        --query "Reservations[].Instances[].InstanceId" \
        --output text 2>/dev/null || true)

    read -r -a ids <<< "$ids_text"
    terminate_instances "${ids[@]}"
}

if [[ -z "$COMMAND" ]]; then
    usage
    exit 1
fi

case "$COMMAND" in
    --list) list_workers ;;
    --all) terminate_all ;;
    instances) terminate_instances "${INSTANCE_IDS[@]}" ;;
    *) echo "ERROR: Unknown command '${COMMAND}'" >&2; usage; exit 1 ;;
esac

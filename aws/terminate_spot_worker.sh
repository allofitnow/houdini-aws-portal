#!/usr/bin/env bash
# terminate_spot_worker.sh
# List or terminate g6e.4xlarge Spot workers tagged project=deadline-worker.
# Preconditions:
#   - AWS CLI configured for account 774538489810, region us-west-2
#
# Usage:
#   ./terminate_spot_worker.sh --list           List running workers
#   ./terminate_spot_worker.sh <instance-id>    Terminate specific instance
#   ./terminate_spot_worker.sh --all            Terminate all project workers

set -euo pipefail

REGION="us-west-2"
TAG_FILTER="Name=tag:project,Values=deadline-worker"
STATE_FILTER="Name=instance-state-name,Values=running,pending"

list_workers() {
    aws ec2 describe-instances \
        --region "$REGION" \
        --filters "$TAG_FILTER" "$STATE_FILTER" \
        --query "Reservations[].Instances[].[InstanceId,State.Name,LaunchTime,Tags[?Key=='Name']|[0].Value]" \
        --output table
}

terminate_one() {
    local id="$1"
    aws ec2 terminate-instances \
        --region "$REGION" \
        --instance-ids "$id" \
        --query "TerminatingInstances[0].[InstanceId,CurrentState.Name]" \
        --output table
    echo "Terminated: ${id}"
}

terminate_all() {
    mapfile -t ids < <(aws ec2 describe-instances \
        --region "$REGION" \
        --filters "$TAG_FILTER" "$STATE_FILTER" \
        --query "Reservations[].Instances[].InstanceId" \
        --output text)

    # Filter out empty lines that --output text may produce when no results
    local clean_ids=()
    for id in "${ids[@]}"; do
        [[ -n "$id" ]] && clean_ids+=("$id")
    done

    if [[ ${#clean_ids[@]} -eq 0 ]]; then
        echo "No running deadline-worker instances found."
        return
    fi

    echo "Terminating ${#clean_ids[@]} instance(s): ${clean_ids[*]}"
    aws ec2 terminate-instances \
        --region "$REGION" \
        --instance-ids "${clean_ids[@]}" \
        --query "TerminatingInstances[].[InstanceId,CurrentState.Name]" \
        --output table
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

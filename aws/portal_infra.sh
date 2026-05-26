#!/usr/bin/env bash
# portal_infra.sh
# Monitor and tear down Deadline AWS Portal infrastructure in us-west-2.
# Portal infrastructure is managed via CloudFormation stacks created by Deadline.
# STARTING an infrastructure must be done via Deadline Monitor (View → AWS Portal → Start Infrastructure).
# STOPPING and STATUS can be handled by this script.
# Preconditions:
#   - AWS CLI configured for account 774538489810, region us-west-2
#   - Deadline AWS Portal has been set up (Portal Link + Asset Server installed)

set -euo pipefail

REGION="us-west-2"

# --- Helper functions ---

# Portal CloudFormation stacks are prefixed with "stack" or "deadline"
get_portal_stacks() {
    aws cloudformation list-stacks \
        --region "$REGION" \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
        --query "StackSummaries[?starts_with(StackName,'stack') || starts_with(StackName,'deadline')].[StackName,StackStatus]" \
        --output table 2>/dev/null || echo "No Portal stacks found."
}

# Gateway instances are tagged Name=Gateway (or ReverseForwarder for older versions)
get_gateway_instances() {
    aws ec2 describe-instances \
        --region "$REGION" \
        --filters "Name=tag:Name,Values=Gateway" "Name=instance-state-name,Values=running,pending" \
        --query "Reservations[].Instances[].[InstanceId,State.Name,InstanceType,PublicIpAddress]" \
        --output table 2>/dev/null || echo "No Gateway instances found."
}

# Portal workers use AWSPortalWorkerRole instance profile
get_portal_workers() {
    aws ec2 describe-instances \
        --region "$REGION" \
        --filters "Name=iam-instance-profile.arn,Values=*AWSPortalWorker*" "Name=instance-state-name,Values=running,pending" \
        --query "Reservations[].Instances[].[InstanceId,State.Name,InstanceType,LaunchTime]" \
        --output table 2>/dev/null || echo "No Portal worker instances found."
}

# Spot fleet requests managed by Portal
get_spot_fleets() {
    aws ec2 describe-spot-fleet-requests \
        --region "$REGION" \
        --query "SpotFleetRequestConfigs[?starts_with(SpotFleetRequestId,'sfr')].[SpotFleetRequestId,SpotFleetRequestState,FulfilledCapacity,TargetCapacity]" \
        --output table 2>/dev/null || echo "No Spot Fleet requests found."
}

# --- Commands ---

cmd_status() {
    echo "=== AWS Portal Infrastructure Status (${REGION}) ==="
    echo ""

    echo "-- CloudFormation Stacks --"
    get_portal_stacks
    echo ""

    echo "-- Gateway Instance --"
    get_gateway_instances
    echo ""

    echo "-- Portal Workers --"
    get_portal_workers
    echo ""

    echo "-- Spot Fleet Requests --"
    get_spot_fleets
    echo ""

    # Cost reminder
    local gateway_count
    gateway_count=$(aws ec2 describe-instances \
        --region "$REGION" \
        --filters "Name=tag:Name,Values=Gateway" "Name=instance-state-name,Values=running" \
        --query "length(Reservations[].Instances[])" \
        --output text 2>/dev/null || echo "0")

    local worker_count
    worker_count=$(aws ec2 describe-instances \
        --region "$REGION" \
        --filters "Name=iam-instance-profile.arn,Values=*AWSPortalWorker*" "Name=instance-state-name,Values=running" \
        --query "length(Reservations[].Instances[])" \
        --output text 2>/dev/null || echo "0")

    if [[ "${gateway_count}" != "0" || "${worker_count}" != "0" ]]; then
        echo "!! ${gateway_count} Gateway(s) + ${worker_count} Worker(s) are running."
        echo "!! Estimated cost: ~\$$(echo "${gateway_count} * 0.05 + ${worker_count} * 1.00" | bc)/hr"
        echo "!! Run '$0 stop' when not rendering to avoid charges."
    else
        echo "No Portal resources running. Safe."
    fi
}

cmd_stop() {
    echo "=== Stopping AWS Portal Infrastructure ==="
    echo ""

    # 1. Cancel all Spot Fleet requests (terminates workers)
    local sfr_ids
    sfr_ids=$(aws ec2 describe-spot-fleet-requests \
        --region "$REGION" \
        --query "SpotFleetRequestConfigs[?SpotFleetRequestState=='submitted' || SpotFleetRequestState=='active'].SpotFleetRequestId" \
        --output text 2>/dev/null || true)

    if [[ -n "${sfr_ids}" ]]; then
        echo "Cancelling Spot Fleet requests: ${sfr_ids}"
        for sfr_id in ${sfr_ids}; do
            aws ec2 cancel-spot-fleet-requests \
                --region "$REGION" \
                --spot-fleet-request-ids "${sfr_id}" \
                --terminate-instances \
                --query "Successful[0].CurrentState" \
                --output text
        done
        echo "Spot Fleets cancelled. Workers terminating."
    else
        echo "No active Spot Fleet requests."
    fi

    echo ""

    # 2. Delete Portal CloudFormation stacks (terminates Gateway + VPC resources)
    local stack_names
    stack_names=$(aws cloudformation list-stacks \
        --region "$REGION" \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
        --query "StackSummaries[?starts_with(StackName,'stack') || starts_with(StackName,'deadline')].StackName" \
        --output text 2>/dev/null || true)

    if [[ -n "${stack_names}" ]]; then
        for stack_name in ${stack_names}; do
            echo "Deleting CloudFormation stack: ${stack_name}"
            aws cloudformation delete-stack \
                --region "$REGION" \
                --stack-name "${stack_name}"
        done
        echo "Stacks deleting. This may take 5-10 minutes."
        echo "Monitor with: aws cloudformation list-stacks --region ${REGION}"
    else
        echo "No Portal CloudFormation stacks to delete."
    fi

    echo ""
    echo "Infrastructure stop initiated."
    echo "Run '$0 status' to verify all resources are terminated."
}

cmd_start() {
    echo "=== Starting AWS Portal Infrastructure ==="
    echo ""
    echo "Portal infrastructure must be started from Deadline Monitor:"
    echo "  1. Open Deadline Monitor"
    echo "  2. View → New Panel → AWS Portal"
    echo "  3. Right-click → Start Infrastructure"
    echo "  4. Select region us-west-2"
    echo ""
    echo "Once infrastructure is running, start a Spot Fleet:"
    echo "  5. Right-click Infrastructure → Start Spot Fleet"
    echo "  6. Check 'Use AMI ID' → ami-0f70342f66dc80ddb"
    echo "  7. Target Capacity: 1, Instance: g6e.4xlarge"
    echo "  8. Pool: houdini-aws-gpu, Auto Shutdown: 15 min"
    echo "  9. Launch"
    echo ""
    echo "After first-time creation, this script can manage stop/status."
}

# --- Main ---

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 {status|stop|start}" >&2
    exit 1
fi

case "$1" in
    status) cmd_status ;;
    stop)   cmd_stop ;;
    start)  cmd_start ;;
    *)
        echo "ERROR: Unknown command '${1}'" >&2
        echo "Usage: $0 {status|stop|start}" >&2
        exit 1
        ;;
esac

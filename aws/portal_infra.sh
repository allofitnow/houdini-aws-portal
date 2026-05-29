#!/usr/bin/env bash
# portal_infra.sh
# Monitor and tear down Deadline AWS Portal infrastructure for the selected AWS region.
# Portal infrastructure is managed via CloudFormation stacks created by Deadline.
# STARTING an infrastructure must be done via Deadline Monitor.
# STOPPING and STATUS can be handled by this script.
# Preconditions:
#   - AWS CLI configured for account 774538489810
#   - Deadline AWS Portal has been set up (Portal Link + Asset Server installed)
#   - Each worker region has its own Portal infrastructure stack and UBL endpoint

set -euo pipefail

REGION="${REGION:-${AWS_REGION:-us-west-2}}"
SPOT_AMI_ID="${SPOT_AMI_ID:-${AMI_ID:-}}"
SPOT_INSTANCE_TYPE="${SPOT_INSTANCE_TYPE:-g6e.4xlarge}"
SPOT_POOL="${SPOT_POOL:-houdini-aws-gpu}"
SPOT_TARGET_CAPACITY="${SPOT_TARGET_CAPACITY:-1}"
SPOT_AUTO_SHUTDOWN_MINUTES="${SPOT_AUTO_SHUTDOWN_MINUTES:-15}"
COMMAND=""

usage() {
    cat >&2 <<USAGE
Usage: $0 [--region REGION] {status|stop|start}

Environment overrides:
  REGION / AWS_REGION             AWS region to inspect or manage
  SPOT_AMI_ID / AMI_ID            Region-local worker AMI ID to paste in Portal
  SPOT_INSTANCE_TYPE              Instance type for Portal Spot Fleet guidance
  SPOT_POOL                       Deadline pool for Portal Spot Fleet guidance
  SPOT_TARGET_CAPACITY            Target capacity for Portal Spot Fleet guidance
  SPOT_AUTO_SHUTDOWN_MINUTES      Portal idle auto-shutdown guidance
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region|--aws-region)
            REGION="$2"
            shift 2
            ;;
        --ami-id)
            SPOT_AMI_ID="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        status|stop|start)
            COMMAND="$1"
            shift
            ;;
        *)
            echo "ERROR: Unknown argument '$1'" >&2
            usage
            exit 1
            ;;
    esac
done

# Portal CloudFormation stacks are prefixed with "stack" or "deadline".
get_portal_stacks() {
    aws cloudformation list-stacks \
        --region "$REGION" \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
        --query "StackSummaries[?starts_with(StackName,'stack') || starts_with(StackName,'deadline')].[StackName,StackStatus]" \
        --output table 2>/dev/null || echo "No Portal stacks found."
}

# Gateway instances are tagged Name=Gateway (or ReverseForwarder for older versions).
get_gateway_instances() {
    aws ec2 describe-instances \
        --region "$REGION" \
        --filters "Name=tag:Name,Values=Gateway" "Name=instance-state-name,Values=running,pending" \
        --query "Reservations[].Instances[].[InstanceId,State.Name,InstanceType,PublicIpAddress]" \
        --output table 2>/dev/null || echo "No Gateway instances found."
}

# Portal workers use AWSPortalWorkerRole instance profile.
get_portal_workers() {
    aws ec2 describe-instances \
        --region "$REGION" \
        --filters "Name=iam-instance-profile.arn,Values=*AWSPortalWorker*" "Name=instance-state-name,Values=running,pending" \
        --query "Reservations[].Instances[].[InstanceId,State.Name,InstanceType,LaunchTime]" \
        --output table 2>/dev/null || echo "No Portal worker instances found."
}

# Spot fleet requests managed by Portal.
get_spot_fleets() {
    aws ec2 describe-spot-fleet-requests \
        --region "$REGION" \
        --query "SpotFleetRequestConfigs[?starts_with(SpotFleetRequestId,'sfr')].[SpotFleetRequestId,SpotFleetRequestState,FulfilledCapacity,TargetCapacity]" \
        --output table 2>/dev/null || echo "No Spot Fleet requests found."
}

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
        echo "!! Run '$0 --region ${REGION} stop' when not rendering to avoid charges."
    else
        echo "No Portal resources running in ${REGION}. Safe."
    fi
}

cmd_stop() {
    echo "=== Stopping AWS Portal Infrastructure (${REGION}) ==="
    echo ""

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
    echo "Infrastructure stop initiated for ${REGION}."
    echo "Run '$0 --region ${REGION} status' to verify all resources are terminated."
}

cmd_start() {
    echo "=== Starting AWS Portal Infrastructure (${REGION}) ==="
    echo ""
    echo "Portal infrastructure must be started from Deadline Monitor for each worker region:"
    echo "  1. Open Deadline Monitor"
    echo "  2. Tools → Power User Mode"
    echo "  3. View → New Panels → AWS Portal"
    echo "  4. Right-click → Start Infrastructure"
    echo "  5. Select region ${REGION}"
    echo ""
    echo "Once infrastructure is running, start a Spot Fleet in ${REGION}:"
    if [[ -n "$SPOT_AMI_ID" ]]; then
        echo "  6. Check 'Use AMI ID' → ${SPOT_AMI_ID}"
    else
        echo "  6. Check 'Use AMI ID' → paste the worker AMI copied into ${REGION}"
    fi
    echo "  7. Target Capacity: ${SPOT_TARGET_CAPACITY}, Instance: ${SPOT_INSTANCE_TYPE}"
    echo "  8. Pool: ${SPOT_POOL}, Auto Shutdown: ${SPOT_AUTO_SHUTDOWN_MINUTES} min"
    echo "  9. Launch"
    echo ""
    echo "Repeat this per region where capacity may be sourced; Deadline/RCS remains central."
}

if [[ -z "$COMMAND" ]]; then
    usage
    exit 1
fi

case "$COMMAND" in
    status) cmd_status ;;
    stop)   cmd_stop ;;
    start)  cmd_start ;;
    *)
        echo "ERROR: Unknown command '${COMMAND}'" >&2
        usage
        exit 1
        ;;
esac

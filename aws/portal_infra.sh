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
CLEANUP_DEADLINE_LICENSE_ENDPOINTS="${CLEANUP_DEADLINE_LICENSE_ENDPOINTS:-true}"
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
  CLEANUP_DEADLINE_LICENSE_ENDPOINTS
                                  Delete Deadline Cloud license endpoints in Portal VPCs during stop (default: true)
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

# Portal CloudFormation stacks are prefixed with "stack" or "deadline". Include failed
# deletes so status/stop can detect and retry partially deleted infrastructure.
get_portal_stacks() {
    aws cloudformation list-stacks \
        --region "$REGION" \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_IN_PROGRESS DELETE_FAILED ROLLBACK_COMPLETE CREATE_FAILED \
        --query "StackSummaries[?starts_with(StackName,'stack') || starts_with(StackName,'deadline')].[StackName,StackStatus]" \
        --output table 2>/dev/null || echo "No Portal stacks found."
}

get_portal_stack_names() {
    aws cloudformation list-stacks \
        --region "$REGION" \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_IN_PROGRESS DELETE_FAILED ROLLBACK_COMPLETE CREATE_FAILED \
        --query "StackSummaries[?starts_with(StackName,'stack') || starts_with(StackName,'deadline')].StackName" \
        --output text 2>/dev/null || true
}

get_portal_vpcs_for_stacks() {
    local stack_name
    local vpc_ids
    local vpc_id_array

    for stack_name in "$@"; do
        vpc_ids=$(aws cloudformation describe-stack-resources \
            --region "$REGION" \
            --stack-name "$stack_name" \
            --query "StackResources[?ResourceType=='AWS::EC2::VPC'].PhysicalResourceId" \
            --output text 2>/dev/null || true)

        if [[ -n "$vpc_ids" && "$vpc_ids" != "None" ]]; then
            read -r -a vpc_id_array <<< "$vpc_ids"
            printf '%s\n' "${vpc_id_array[@]}"
        fi
    done | sort -u
}

# Gateway instances are tagged Name=Gateway.
get_gateway_instances() {
    aws ec2 describe-instances \
        --region "$REGION" \
        --filters "Name=tag:Name,Values=Gateway" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query "Reservations[].Instances[].[InstanceId,State.Name,InstanceType,VpcId,SubnetId,PublicIpAddress]" \
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

get_vpc_endpoints() {
    aws ec2 describe-vpc-endpoints \
        --region "$REGION" \
        --query "VpcEndpoints[].[VpcEndpointId,State,VpcId,ServiceName,SubnetIds[0]]" \
        --output table 2>/dev/null || echo "No VPC endpoints found."
}

disable_gateway_termination_protection() {
    local vpc_id
    local instance_ids
    local instance_id
    local protected

    for vpc_id in "$@"; do
        instance_ids=$(aws ec2 describe-instances \
            --region "$REGION" \
            --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=Gateway" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
            --query "Reservations[].Instances[].InstanceId" \
            --output text 2>/dev/null || true)

        for instance_id in ${instance_ids}; do
            protected=$(aws ec2 describe-instance-attribute \
                --region "$REGION" \
                --instance-id "$instance_id" \
                --attribute disableApiTermination \
                --query "DisableApiTermination.Value" \
                --output text 2>/dev/null || echo "false")

            if [[ "${protected,,}" == "true" ]]; then
                echo "Disabling API termination protection on Gateway ${instance_id}"
                aws ec2 modify-instance-attribute \
                    --region "$REGION" \
                    --instance-id "$instance_id" \
                    --disable-api-termination '{"Value":false}'
            fi
        done
    done
}

delete_deadline_license_endpoints_for_vpcs() {
    local vpc_id
    local license_endpoint_ids
    local license_endpoint_id

    if [[ "$CLEANUP_DEADLINE_LICENSE_ENDPOINTS" != "true" ]]; then
        echo "Skipping Deadline Cloud license endpoint cleanup because CLEANUP_DEADLINE_LICENSE_ENDPOINTS=${CLEANUP_DEADLINE_LICENSE_ENDPOINTS}."
        return
    fi

    for vpc_id in "$@"; do
        license_endpoint_ids=$(aws deadline list-license-endpoints \
            --region "$REGION" \
            --query "licenseEndpoints[?vpcId=='${vpc_id}'].licenseEndpointId" \
            --output text 2>/dev/null || true)

        for license_endpoint_id in ${license_endpoint_ids}; do
            echo "Deleting Deadline Cloud license endpoint ${license_endpoint_id} in ${vpc_id}"
            aws deadline delete-license-endpoint \
                --region "$REGION" \
                --license-endpoint-id "$license_endpoint_id" || true
        done
    done
}

delete_orphan_vpc_endpoints_for_vpcs() {
    local vpc_id
    local vpc_endpoint_ids
    local vpc_endpoint_array

    for vpc_id in "$@"; do
        vpc_endpoint_ids=$(aws ec2 describe-vpc-endpoints \
            --region "$REGION" \
            --filters "Name=vpc-id,Values=${vpc_id}" \
            --query "VpcEndpoints[?length(Tags[?Key=='aws:cloudformation:stack-name']) == \`0\`].VpcEndpointId" \
            --output text 2>/dev/null || true)

        if [[ -n "$vpc_endpoint_ids" && "$vpc_endpoint_ids" != "None" ]]; then
            read -r -a vpc_endpoint_array <<< "$vpc_endpoint_ids"
            echo "Deleting non-CloudFormation VPC endpoints in ${vpc_id}: ${vpc_endpoint_ids}"
            aws ec2 delete-vpc-endpoints \
                --region "$REGION" \
                --vpc-endpoint-ids "${vpc_endpoint_array[@]}" \
                --output text || true
        fi
    done
}

empty_stack_s3_buckets() {
    local stack_name
    local bucket_names
    local bucket_array
    local bucket

    for stack_name in "$@"; do
        bucket_names=$(aws cloudformation describe-stack-resources \
            --region "$REGION" \
            --stack-name "$stack_name" \
            --query "StackResources[?ResourceType=='AWS::S3::Bucket' && ResourceStatus!='DELETE_COMPLETE'].PhysicalResourceId" \
            --output text 2>/dev/null || true)

        if [[ -z "$bucket_names" || "$bucket_names" == "None" ]]; then
            continue
        fi

        read -r -a bucket_array <<< "$bucket_names"
        for bucket in "${bucket_array[@]}"; do
            echo "Emptying versioned S3 bucket before stack delete: ${bucket}"
            python3 - "$REGION" "$bucket" <<'PY'
import json
import subprocess
import sys
import tempfile

region, bucket = sys.argv[1], sys.argv[2]

list_result = subprocess.run(
    [
        "aws", "s3api", "list-object-versions",
        "--region", region,
        "--bucket", bucket,
        "--output", "json",
    ],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)

if list_result.returncode != 0:
    print(f"  WARN: unable to list {bucket}; it may already be deleted.", file=sys.stderr)
    sys.exit(0)

versions = json.loads(list_result.stdout or "{}")
objects = []
for collection in ("Versions", "DeleteMarkers"):
    for item in versions.get(collection, []) or []:
        objects.append({"Key": item["Key"], "VersionId": item["VersionId"]})

if not objects:
    print("  Already empty.")
    sys.exit(0)

for start in range(0, len(objects), 1000):
    chunk = objects[start:start + 1000]
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", delete=False) as handle:
        json.dump({"Objects": chunk, "Quiet": True}, handle)
        delete_file = handle.name

    subprocess.run(
        [
            "aws", "s3api", "delete-objects",
            "--region", region,
            "--bucket", bucket,
            "--delete", f"file://{delete_file}",
            "--output", "json",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    print(f"  Deleted {len(chunk)} object version/delete marker entries.")
PY
        done
    done
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

    echo "-- VPC Endpoints --"
    get_vpc_endpoints
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
        echo "!! ${gateway_count} Gateway(s) + ${worker_count} Worker(s) are running and may incur charges."
        echo "!! Run '$0 --region ${REGION} stop' when not rendering."
    else
        echo "No Portal Gateway or worker instances running in ${REGION}."
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
    stack_names=$(get_portal_stack_names)

    if [[ -n "${stack_names}" ]]; then
        local stack_name_array
        local vpc_ids
        read -r -a stack_name_array <<< "$stack_names"
        readarray -t vpc_ids < <(get_portal_vpcs_for_stacks "${stack_name_array[@]}")

        if [[ "${#vpc_ids[@]}" -gt 0 ]]; then
            echo "Preparing Portal VPC dependencies for deletion: ${vpc_ids[*]}"
            delete_deadline_license_endpoints_for_vpcs "${vpc_ids[@]}"
            delete_orphan_vpc_endpoints_for_vpcs "${vpc_ids[@]}"
            disable_gateway_termination_protection "${vpc_ids[@]}"
            echo ""
        fi

        empty_stack_s3_buckets "${stack_name_array[@]}"
        echo ""

        for stack_name in "${stack_name_array[@]}"; do
            echo "Deleting/retrying CloudFormation stack: ${stack_name}"
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
    echo "Success is verified by CloudFormation CREATE_COMPLETE and a running Gateway instance; AWS Portal may not show a final success popup."
    echo "Check with: $0 --region ${REGION} status"
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
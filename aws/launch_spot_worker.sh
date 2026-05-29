#!/usr/bin/env bash
# launch_spot_worker.sh
# Legacy/manual launcher for one or more Spot workers from a region-local worker AMI.
# Prefer launch_ready_spot_worker.sh for multi-region fallback, UBL runtime defaults,
# certificate staging, ZeroTier authorization, and Deadline registration checks.
#
# Preconditions:
#   - .env present in project root or env vars exported with SUBNET_ID and SG_ID
#   - AWS CLI configured for account 774538489810
#   - AMI_ID is available in the selected region

set -euo pipefail

REGION="${REGION:-${AWS_REGION:-us-west-2}}"
AMI_ID="${AMI_ID:-ami-0f70342f66dc80ddb}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g6.xlarge}"
PROFILE="${PROFILE:-deadline-worker-profile}"
SG_ID="${SG_ID:-}"
SUBNET_ID="${SUBNET_ID:-}"
COUNT="1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

usage() {
    cat >&2 <<USAGE
Usage: $0 [COUNT] [--region REGION] [--ami-id AMI] [--subnet-id SUBNET] [--sg-id SG]

This is a minimal manual launcher. For production multi-region fallback, use:
  READY_WORKER_REGIONS=${REGION} ./aws/launch_ready_spot_worker.sh
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region|--aws-region) REGION="$2"; shift 2 ;;
        --ami-id) AMI_ID="$2"; shift 2 ;;
        --subnet-id) SUBNET_ID="$2"; shift 2 ;;
        --sg-id|--security-group-id) SG_ID="$2"; shift 2 ;;
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        [1-9]* ) COUNT="$1"; shift ;;
        *) echo "ERROR: Unknown argument '$1'" >&2; usage; exit 1 ;;
    esac
done

if [[ -z "${SUBNET_ID:-}" || -z "${SG_ID:-}" ]]; then
    echo "ERROR: SUBNET_ID and SG_ID are required. Add them to .env, export them, or pass --subnet-id/--sg-id." >&2
    exit 1
fi

if ! [[ "$COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Count must be a positive integer, got '${COUNT}'." >&2
    exit 1
fi

MARKET_OPTIONS='{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"one-time"}}'

echo "Launching ${COUNT} spot worker(s) in ${REGION}..."
echo ""

for (( i=1; i<=COUNT; i++ )); do
    NAME="deadline-worker-$(date +%s)"
    INSTANCE_ID=$(aws ec2 run-instances \
        --region "$REGION" \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --iam-instance-profile Name="$PROFILE" \
        --subnet-id "$SUBNET_ID" \
        --security-group-ids "$SG_ID" \
        --instance-market-options "$MARKET_OPTIONS" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=project,Value=deadline-worker},{Key=Name,Value=${NAME}},{Key=Region,Value=${REGION}}]" \
        --query "Instances[0].InstanceId" \
        --output text)

    SPOT_ID=$(aws ec2 describe-instances \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].SpotInstanceRequestId" \
        --output text)

    echo "  [${i}/${COUNT}] Instance : ${INSTANCE_ID}"
    echo "        Region   : ${REGION}"
    echo "        Spot req : ${SPOT_ID}"
done

echo ""
echo "Next step: authorize each new ZeroTier node at"
echo "  https://my.zerotier.com/network/d3ecf5726d14ac76"
echo "Workers appear in Deadline Monitor within ~3-5 min of ZeroTier auth."

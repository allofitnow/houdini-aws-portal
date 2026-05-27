#!/usr/bin/env bash
# launch_spot_worker.sh
# Launch one or more g6e.4xlarge Spot workers from the validated deadline worker AMI.
# Workers connect to the Deadline repository via ZeroTier + systemd on first boot.
# Preconditions:
#   - .env present in project root with SUBNET_ID set
#   - AWS CLI configured for account 774538489810, region us-west-2
#   - AMI ami-0f70342f66dc80ddb is available in us-west-2

set -euo pipefail

REGION="us-west-2"
AMI_ID="ami-0f70342f66dc80ddb"
INSTANCE_TYPE="g6.xlarge"
PROFILE="deadline-worker-profile"
SG_ID="sg-0f7755ef50058d7a1"
COUNT="${1:-1}"

# Source .env for SUBNET_ID (and any local overrides)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

if [[ -z "${SUBNET_ID:-}" ]]; then
    echo "ERROR: SUBNET_ID not set. Add SUBNET_ID=<value> to .env or export it." >&2
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
        --tag-specifications "ResourceType=instance,Tags=[{Key=project,Value=deadline-worker},{Key=Name,Value=${NAME}}]" \
        --query "Instances[0].InstanceId" \
        --output text)

    SPOT_ID=$(aws ec2 describe-instances \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].SpotInstanceRequestId" \
        --output text)

    echo "  [${i}/${COUNT}] Instance : ${INSTANCE_ID}"
    echo "        Spot req : ${SPOT_ID}"
done

echo ""
echo "Next step: authorize each new ZeroTier node at"
echo "  https://my.zerotier.com/network/d3ecf5726d14ac76"
echo "Workers appear in Deadline Monitor within ~3-5 min of ZeroTier auth."

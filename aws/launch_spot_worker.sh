#!/usr/bin/env bash
# launch_spot_worker.sh
# Legacy/manual launcher for one or more workers from a region-local worker AMI.
# Prefer launch_ready_spot_worker.sh for production multi-region fallback because it
# configures UBL runtime defaults, cert staging, ZeroTier authorization, and Deadline checks.

set -euo pipefail

REGION="${REGION:-${AWS_REGION:-us-west-2}}"
AMI_ID="${AMI_ID:-ami-0f70342f66dc80ddb}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g6e.4xlarge}"
MARKET_TYPE="${MARKET_TYPE:-on-demand}"
IAM_PROFILE="${IAM_PROFILE:-${PROFILE:-deadline-worker-profile}}"
SG_ID="${SG_ID:-}"
SUBNET_ID="${SUBNET_ID:-}"
VPC_ID="${VPC_ID:-}"
KEY_NAME="${KEY_NAME:-deadline-ami-build}"
TAG_PROJECT="${TAG_PROJECT:-deadline-worker}"
ZT_NETWORK="${ZT_NETWORK:-${ZT_NETWORK_ID:-d3ecf5726d14ac76}}"
ZT_TOKEN="${ZEROTIER_API_TOKEN:-}"
COUNT="1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

usage() {
    cat >&2 <<USAGE
Usage: $0 [COUNT] [options]

Options:
  --region REGION           AWS region
  --ami-id AMI              Region-local worker AMI
  --instance-type TYPE      Worker instance type
  --market-type TYPE        on-demand or spot
  --subnet-id SUBNET        Specific subnet to launch in
  --vpc-id VPC              VPC for public subnet discovery when SUBNET_ID is unset
  --sg-id SG                Worker security group
  --key-name NAME           EC2 key pair
  --profile NAME            IAM instance profile

For production multi-region fallback, use launch_ready_spot_worker.sh.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region|--aws-region) REGION="$2"; shift 2 ;;
        --ami-id) AMI_ID="$2"; shift 2 ;;
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --market-type) MARKET_TYPE="$2"; shift 2 ;;
        --subnet-id) SUBNET_ID="$2"; shift 2 ;;
        --vpc-id) VPC_ID="$2"; shift 2 ;;
        --sg-id|--security-group-id) SG_ID="$2"; shift 2 ;;
        --key-name) KEY_NAME="$2"; shift 2 ;;
        --profile|--iam-profile) IAM_PROFILE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        [1-9]* ) COUNT="$1"; shift ;;
        *) echo "ERROR: Unknown argument '$1'" >&2; usage; exit 1 ;;
    esac
done

if ! [[ "$COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Count must be a positive integer, got '${COUNT}'." >&2
    exit 1
fi

if [[ -z "$SG_ID" ]]; then
    echo "ERROR: SG_ID is required. Add it to .env, export it, or pass --sg-id." >&2
    exit 1
fi

if [[ "$MARKET_TYPE" != "on-demand" && "$MARKET_TYPE" != "spot" ]]; then
    echo "ERROR: MARKET_TYPE must be on-demand or spot, got '${MARKET_TYPE}'." >&2
    exit 1
fi

AMI_STATE=$(aws ec2 describe-images \
    --image-ids "$AMI_ID" \
    --region "$REGION" \
    --query "Images[0].State" \
    --output text 2>/dev/null || echo "missing")

if [[ "$AMI_STATE" != "available" ]]; then
    echo "ERROR: AMI $AMI_ID is not available in ${REGION} (state: $AMI_STATE)" >&2
    exit 1
fi

PRICE_CAP=$(aws ec2 describe-spot-price-history \
    --instance-types "$INSTANCE_TYPE" \
    --product-descriptions "Linux/UNIX" \
    --region "$REGION" \
    --max-items 1 \
    --query "SpotPriceHistory[0].SpotPrice" \
    --output text 2>/dev/null || echo "2.000")
CAP=$(awk -v price="$PRICE_CAP" 'BEGIN { cap = price * 1.5; if (cap > 2.0) cap = 2.0; printf "%.3f", cap }')

SUBNETS=()
if [[ -n "$SUBNET_ID" ]]; then
    read -r -a SUBNETS <<< "$SUBNET_ID"
elif [[ -n "$VPC_ID" ]]; then
    while IFS= read -r sid; do
        [[ -n "$sid" ]] && SUBNETS+=("$sid")
    done < <(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
        --region "$REGION" \
        --query "Subnets[].SubnetId" \
        --output text 2>/dev/null | tr '\t' '\n')
else
    echo "ERROR: SUBNET_ID or VPC_ID is required for legacy launch_spot_worker.sh." >&2
    exit 1
fi

if (( ${#SUBNETS[@]} == 0 )); then
    echo "ERROR: No launch subnets found in ${REGION}." >&2
    exit 1
fi

echo "==> Launching $COUNT x $INSTANCE_TYPE ($MARKET_TYPE) worker(s) in ${REGION}"
echo "    AMI:      $AMI_ID"
echo "    SG:       $SG_ID"
echo "    Profile:  $IAM_PROFILE"
echo "    Subnets:  ${SUBNETS[*]}"
if [[ "$MARKET_TYPE" == "spot" ]]; then
    echo "    Spot cap: \$$CAP/hr"
fi

TIMESTAMP=$(date +%s)
LAUNCH_RESULT=""
LAUNCHED=false

for SUBNET in "${SUBNETS[@]}"; do
    echo ""
    echo "==> Trying subnet $SUBNET..."

    MARKET_OPTS=()
    TAG_SPECS=("ResourceType=instance,Tags=[{Key=project,Value=$TAG_PROJECT},{Key=Name,Value=deadline-worker-$TIMESTAMP},{Key=market,Value=$MARKET_TYPE},{Key=Region,Value=$REGION}]")
    if [[ "$MARKET_TYPE" == "spot" ]]; then
        MARKET_OPTS=(--instance-market-options "MarketType=spot,SpotOptions={MaxPrice=$CAP,SpotInstanceType=one-time}")
        TAG_SPECS+=("ResourceType=spot-instances-request,Tags=[{Key=project,Value=$TAG_PROJECT}]")
    fi

    LAUNCH_RESULT=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        "${MARKET_OPTS[@]}" \
        --iam-instance-profile "Name=$IAM_PROFILE" \
        --security-group-ids "$SG_ID" \
        --subnet-id "$SUBNET" \
        --key-name "$KEY_NAME" \
        --count "$COUNT" \
        --tag-specifications "${TAG_SPECS[@]}" \
        --region "$REGION" \
        --output json 2>&1) && LAUNCHED=true

    if $LAUNCHED; then
        break
    fi

    if grep -q "InsufficientInstanceCapacity" <<< "$LAUNCH_RESULT"; then
        AZ=$(aws ec2 describe-subnets --subnet-ids "$SUBNET" --region "$REGION" \
            --query "Subnets[0].AvailabilityZone" --output text 2>/dev/null || echo "unknown")
        echo "    No capacity in $AZ, trying next subnet..."
        continue
    fi

    echo "ERROR: Launch failed" >&2
    echo "$LAUNCH_RESULT" >&2
    exit 1
done

if ! $LAUNCHED; then
    echo "ERROR: InsufficientInstanceCapacity in all ${#SUBNETS[@]} subnets." >&2
    exit 1
fi

INSTANCE_IDS=$(jq -r '.Instances[].InstanceId' <<< "$LAUNCH_RESULT" 2>/dev/null || true)
if [[ -z "$INSTANCE_IDS" ]]; then
    echo "ERROR: Failed to parse launched instances." >&2
    echo "$LAUNCH_RESULT" >&2
    exit 1
fi

echo ""
echo "==> Launched successfully:"
for IID in $INSTANCE_IDS; do
    echo "    $IID"
done

echo ""
echo "==> Waiting for instances to reach running state..."
# shellcheck disable=SC2086
aws ec2 wait instance-running --instance-ids $INSTANCE_IDS --region "$REGION" --no-paginate 2>/dev/null || true

echo ""
echo "==> Instance details:"
# shellcheck disable=SC2086
aws ec2 describe-instances \
    --instance-ids $INSTANCE_IDS \
    --region "$REGION" \
    --query "Reservations[].Instances[].{ID:InstanceId,State:State.Name,IP:PublicIpAddress,Type:InstanceType}" \
    --output table

if [[ -n "$ZT_TOKEN" ]]; then
    echo ""
    echo "==> ZeroTier: waiting for new nodes to join network $ZT_NETWORK..."
    AUTH_OK=0
    for ATTEMPT in $(seq 1 12); do
        sleep 10
        ALL_NODES=$(curl -sf -H "Authorization: token $ZT_TOKEN" \
            "https://my.zerotier.com/api/v1/network/$ZT_NETWORK/member" 2>/dev/null || echo "[]")
        NEW_NODES=$(jq -r '[.[] | select(.config.authorized==false) | .nodeId] | join(" ")' <<< "$ALL_NODES" 2>/dev/null || echo "")

        if [[ -z "$NEW_NODES" ]]; then
            echo "    [$ATTEMPT/12] No new unauthorized nodes yet..."
            continue
        fi

        for NODE_ID in $NEW_NODES; do
            echo "    Authorizing ZeroTier node $NODE_ID..."
            RESULT=$(curl -sf -X POST \
                -H "Authorization: token $ZT_TOKEN" \
                -H "Content-Type: application/json" \
                -d '{"config":{"authorized":true}}' \
                "https://my.zerotier.com/api/v1/network/$ZT_NETWORK/member/$NODE_ID" 2>&1 || true)
            if jq -e '.config.authorized==true' <<< "$RESULT" >/dev/null 2>&1; then
                ZT_IP=$(jq -r '.config.ipAssignments[0] // "pending"' <<< "$RESULT")
                echo "    OK: node $NODE_ID authorized (IP: $ZT_IP)"
                AUTH_OK=$((AUTH_OK + 1))
            else
                echo "    WARN: authorization response for $NODE_ID: ${RESULT:0:200}"
            fi
        done

        if (( AUTH_OK >= COUNT )); then
            break
        fi
    done

    if (( AUTH_OK == 0 )); then
        echo "    WARN: No new ZeroTier nodes detected after 120s"
        echo "    Authorize manually: https://my.zerotier.com/network/$ZT_NETWORK"
    fi
else
    echo ""
    echo "==> WARN: ZEROTIER_API_TOKEN not set — skipping auto-authorization"
    echo "    Authorize manually: https://my.zerotier.com/network/$ZT_NETWORK"
fi

echo ""
echo "==> Verifying worker readiness..."
for IID in $INSTANCE_IDS; do
    echo ""
    echo "--- Worker $IID ---"
    PASS=0
    CHECKS=3

    SSM_PING=$(aws ssm describe-instance-information \
        --filters "Key=InstanceIds,Values=$IID" \
        --region "$REGION" \
        --query "InstanceInformationList[0].PingStatus" \
        --output text 2>/dev/null || echo "Offline")
    if [[ "$SSM_PING" == "Online" ]]; then
        echo "    [1/$CHECKS] SSM Agent:    OK"
        PASS=$((PASS + 1))
    else
        echo "    [1/$CHECKS] SSM Agent:    WAIT (PingStatus=$SSM_PING)"
    fi

    if [[ "$SSM_PING" == "Online" ]]; then
        SVC_CMD=$(aws ssm send-command \
            --instance-ids "$IID" \
            --document-name "AWS-RunShellScript" \
            --parameters commands=["systemctl is-active deadline10launcher 2>/dev/null || echo inactive"] \
            --timeout-seconds 30 \
            --region "$REGION" \
            --query "Command.CommandId" \
            --output text 2>/dev/null || true)
        sleep 5
        SVC_OUT=$(aws ssm get-command-invocation \
            --command-id "$SVC_CMD" \
            --instance-id "$IID" \
            --region "$REGION" \
            --query "StandardOutputContent" \
            --output text 2>/dev/null || true)
        if grep -q "active" <<< "$SVC_OUT"; then
            echo "    [2/$CHECKS] Deadline svc: OK"
            PASS=$((PASS + 1))
        else
            echo "    [2/$CHECKS] Deadline svc: WAIT (${SVC_OUT:-unknown})"
        fi
    else
        echo "    [2/$CHECKS] Deadline svc: SKIP (SSM not online)"
    fi

    if [[ -n "$ZT_TOKEN" ]]; then
        echo "    [3/$CHECKS] ZeroTier:     CHECK AUTHORIZED MEMBERS IN UI/API"
    else
        echo "    [3/$CHECKS] ZeroTier:     SKIP (no token)"
    fi

    echo "    Result: $PASS/$CHECKS automated checks passed"
done

echo ""
echo "==> DONE."
echo "    - To terminate: ./aws/terminate_spot_worker.sh --region ${REGION} ${INSTANCE_IDS//$'\n'/ }"

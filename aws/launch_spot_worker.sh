#!/usr/bin/env bash
# aws/launch_spot_worker.sh — Launch spot GPU worker(s) from the validated AMI
# Preconditions: .env sourced, AMI available, ZeroTier network active
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
AMI_ID="ami-0f70342f66dc80ddb"
INSTANCE_TYPE="g6e.4xlarge"
REGION="us-west-2"
IAM_PROFILE="deadline-worker-profile"
SG_ID="${SG_ID:-sg-0f7755ef50058d7a1}"
SUBNET_ID="${SUBNET_ID:-subnet-58e53520}"
KEY_NAME="deadline-ami-build"
TAG_PROJECT="deadline-worker"
ZT_NETWORK="d3ecf5726d14ac76"
ZT_TOKEN="${ZEROTIER_API_TOKEN:-}"
COUNT="${1:-1}"

# ── Validate ──────────────────────────────────────────────────────────────────
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || (( COUNT < 1 )); then
    echo "ERROR: Usage: $0 [COUNT]  (default: 1)"
    exit 1
fi

AMI_STATE=$(aws ec2 describe-images \
    --image-ids "$AMI_ID" \
    --region "$REGION" \
    --query "Images[0].State" \
    --output text 2>/dev/null)

if [[ "$AMI_STATE" != "available" ]]; then
    echo "ERROR: AMI $AMI_ID is not available (state: $AMI_STATE)"
    exit 1
fi

echo "==> Launching $COUNT x $INSTANCE_TYPE spot worker(s)"
echo "    AMI:      $AMI_ID"
echo "    Subnet:   $SUBNET_ID"
echo "    SG:       $SG_ID"
echo "    Profile:  $IAM_PROFILE"
echo ""

# ── Get spot price cap (on-demand price as ceiling) ───────────────────────────
PRICE_CAP=$(aws ec2 describe-spot-price-history \
    --instance-types "$INSTANCE_TYPE" \
    --product-descriptions "Linux/UNIX" \
    --region "$REGION" \
    --max-items 1 \
    --query "SpotPriceHistory[0].SpotPrice" \
    --output text 2>/dev/null || echo "2.000")

# Use 1.5x current spot price or $2.00 max as cap
CAP=$(echo "$PRICE_CAP" | awk '{ cap = $1 * 1.5; if (cap > 2.0) cap = 2.0; printf "%.3f", cap }')
echo "    Spot cap: \$$CAP/hr"

# ── Launch ────────────────────────────────────────────────────────────────────
TIMESTAMP=$(date +%s)

LAUNCH_RESULT=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --instance-market-options "MarketType=spot,SpotOptions={MaxPrice=$CAP,SpotInstanceType=one-time}" \
    --iam-instance-profile "Name=$IAM_PROFILE" \
    --security-group-ids "$SG_ID" \
    --subnet-id "$SUBNET_ID" \
    --key-name "$KEY_NAME" \
    --count "$COUNT" \
    --tag-specifications \
        "ResourceType=instance,Tags=[{Key=project,Value=$TAG_PROJECT},{Key=Name,Value=deadline-worker-$TIMESTAMP}]" \
        "ResourceType=spot-instances-request,Tags=[{Key=project,Value=$TAG_PROJECT}]" \
    --region "$REGION" \
    --output json)

INSTANCE_IDS=$(echo "$LAUNCH_RESULT" | jq -r '.Instances[].InstanceId' 2>/dev/null || true)

if [[ -z "$INSTANCE_IDS" ]]; then
    echo "ERROR: Failed to launch instances"
    echo "$LAUNCH_RESULT"
    exit 1
fi

echo ""
echo "==> Launched successfully:"
for IID in $INSTANCE_IDS; do
    echo "    $IID"
done

# ── Wait for running state ────────────────────────────────────────────────────
echo ""
echo "==> Waiting for instances to reach 'running' state..."
# shellcheck disable=SC2086
aws ec2 wait instance-running \
    --instance-ids $INSTANCE_IDS \
    --region "$REGION" \
    --no-paginate 2>/dev/null || true

echo ""
echo "==> Instance details:"
# shellcheck disable=SC2086
aws ec2 describe-instances \
    --instance-ids $INSTANCE_IDS \
    --region "$REGION" \
    --query "Reservations[].Instances[].{ID:InstanceId,State:State.Name,IP:PublicIpAddress,Type:InstanceType}" \
    --output table

echo ""
echo "==> ZeroTier: waiting for new nodes to join network $ZT_NETWORK..."

# ── ZeroTier auto-authorization ──────────────────────────────────────────────
# Wait up to 120s for new ZeroTier nodes to appear, then authorize them
if [[ -n "$ZT_TOKEN" ]]; then
    AUTH_OK=0
    for ATTEMPT in $(seq 1 12); do
        sleep 10
        # Get all currently-authorized nodes
        ALL_NODES=$(curl -sf -H "Authorization: token $ZT_TOKEN" \
            "https://my.zerotier.com/api/v1/network/$ZT_NETWORK/member" 2>/dev/null || echo "[]")

        # Find unauthorized nodes (new members that just joined)
        NEW_NODES=$(echo "$ALL_NODES" | jq -r \
            "[.[] | select(.config.authorized==false) | .nodeId] | join(\" \")" 2>/dev/null || echo "")

        if [[ -z "$NEW_NODES" ]]; then
            echo "    [$ATTEMPT/12] No new unauthorized nodes yet..."
            continue
        fi

        # Authorize each new node
        for NODE_ID in $NEW_NODES; do
            echo "    Authorizing ZeroTier node $NODE_ID..."
            RESULT=$(curl -sf -X POST \
                -H "Authorization: token $ZT_TOKEN" \
                -H "Content-Type: application/json" \
                -d '{"config":{"authorized":true}}' \
                "https://my.zerotier.com/api/v1/network/$ZT_NETWORK/member/$NODE_ID" 2>&1 || true)

            if echo "$RESULT" | jq -e '.config.authorized==true' >/dev/null 2>&1; then
                ZT_IP=$(echo "$RESULT" | jq -r '.config.ipAssignments[0] // "pending"')
                echo "    OK: node $NODE_ID authorized (IP: $ZT_IP)"
                AUTH_OK=$((AUTH_OK + 1))
            else
                echo "    WARN: authorization response for $NODE_ID: ${RESULT:0:200}"
            fi
        done

        # If we authorized at least COUNT nodes, we're done
        if (( AUTH_OK >= COUNT )); then
            break
        fi
    done

    if (( AUTH_OK == 0 )); then
        echo "    WARN: No new ZeroTier nodes detected after 120s"
        echo "    Authorize manually: https://my.zerotier.com/network/$ZT_NETWORK"
    fi
else
    echo "    WARN: ZEROTIER_API_TOKEN not set — skipping auto-authorization"
    echo "    Authorize manually: https://my.zerotier.com/network/$ZT_NETWORK"
fi

echo ""
echo "==> DONE. Next:"
echo "    - Worker should appear in Deadline Monitor within 3-5 min"
echo "    - To terminate: ./aws/terminate_spot_worker.sh $INSTANCE_IDS"

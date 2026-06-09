#!/usr/bin/env bash
# aws/create_ubl_endpoint.sh
# Create or reuse a Deadline Cloud UBL license endpoint for Portal workers.
# Discovers the active Portal stack, creates/reuses the endpoint, attaches
# SideFX metered products, opens worker SG self-ingress, and writes the
# endpoint DNS to Secrets Manager.
#
# Prerequisites:
#   - Portal infrastructure started from Deadline Monitor (CF stack CREATE_COMPLETE)
#   - AWS CLI configured with deadline:* and ec2:* permissions
#   - jq installed
#
# Usage:
#   ./aws/create_ubl_endpoint.sh --region us-west-2            # apply
#   ./aws/create_ubl_endpoint.sh --region us-west-2 --dry-run  # preview only
#   ./aws/create_ubl_endpoint.sh --region us-west-2 --yes      # skip confirmation

set -euo pipefail

# --- Defaults ---
REGION=""
DRY_RUN=false
YES=false
SECRET_ID="${HOUDINI_LICENSE_ENDPOINT_SECRET_ID:-houdini/license-endpoint-dns}"
METERED_PRODUCTS="houdini-21.0 karma-21.0 mantra-21.0"
LICENSE_PORTS="1715-1717"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)     REGION="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --yes)        YES=true; shift ;;
        --secret-id)  SECRET_ID="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 --region <region> [--dry-run] [--yes] [--secret-id <secret>]"
            echo ""
            echo "Options:"
            echo "  --region      AWS region (required)"
            echo "  --dry-run     Preview changes without applying"
            echo "  --yes         Skip confirmation prompt"
            echo "  --secret-id   Secrets Manager secret name (default: houdini/license-endpoint-dns)"
            exit 0
            ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$REGION" ]]; then
    echo "ERROR: --region is required"
    exit 1
fi

# --- Helpers ---
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# --- Step 1: Discover Portal stack ---
log "Discovering Portal CloudFormation stack in $REGION..."

PARENT_STACK=""
MAPFILE -T STACKS < <(aws cloudformation describe-stacks \
    --region "$REGION" \
    --query "Stacks[?StackStatus=='CREATE_COMPLETE'].StackName" \
    --output text 2>/dev/null | tr '\t' '\n') || die "Failed to list CloudFormation stacks"

for stack in "${STACKS[@]}"; do
    [[ -z "$stack" ]] && continue
    # Check if this stack has the Portal-specific outputs
    HAS_VPC=$(aws cloudformation describe-stacks \
        --region "$REGION" \
        --stack-name "$stack" \
        --query "Stacks[0].Outputs[?OutputKey=='VPCID'].OutputValue" \
        --output text 2>/dev/null || echo "")
    if [[ -n "$HAS_VPC" ]]; then
        HAS_RF=$(aws cloudformation describe-stacks \
            --region "$REGION" \
            --stack-name "$stack" \
            --query "Stacks[0].Outputs[?OutputKey=='ReverseForwarderInstanceId'].OutputValue" \
            --output text 2>/dev/null || echo "")
        if [[ -n "$HAS_RF" ]]; then
            PARENT_STACK="$stack"
            break
        fi
    fi
done

if [[ -z "$PARENT_STACK" ]]; then
    die "No Portal infrastructure stack found in $REGION. Start infrastructure from Deadline Monitor first."
fi

log "Found Portal stack: $PARENT_STACK"

# --- Step 2: Extract VPC, subnet, and security group ---
VPC_ID=$(aws cloudformation describe-stacks \
    --region "$REGION" \
    --stack-name "$PARENT_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='VPCID'].OutputValue" \
    --output text)

MAIN_AZ=$(aws cloudformation describe-stacks \
    --region "$REGION" \
    --stack-name "$PARENT_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='MainAvailabilityZone'].OutputValue" \
    --output text)

AZ_STACK="${PARENT_STACK}-${MAIN_AZ}"
SUBNET_ID=$(aws cloudformation describe-stacks \
    --region "$REGION" \
    --stack-name "$AZ_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='SubnetID'].OutputValue" \
    --output text 2>/dev/null || die "AZ stack $AZ_STACK not found")

# Find ReverseSlaveSG in the Portal VPC
SG_ID=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=*ReverseSlaveSG*" \
    --query "SecurityGroups[0].GroupId" \
    --output text)

if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    die "ReverseSlaveSG not found in VPC $VPC_ID"
fi

log "VPC: $VPC_ID"
log "Subnet ($MAIN_AZ): $SUBNET_ID"
log "Worker SG: $SG_ID"

# --- Step 3: Check for existing license endpoint in this VPC ---
EXISTING_LE=""
EXISTING_DNS=""

LE_IDS=$(aws deadline list-license-endpoints \
    --region "$REGION" \
    --query "licenseEndpoints[].licenseEndpointId" \
    --output text 2>/dev/null || echo "")

for le_id in $LE_IDS; do
    [[ -z "$le_id" ]] && continue
    LE_VPC=$(aws deadline get-license-endpoint \
        --region "$REGION" \
        --license-endpoint-id "$le_id" \
        --query "vpcId" \
        --output text 2>/dev/null || echo "")
    LE_STATUS=$(aws deadline get-license-endpoint \
        --region "$REGION" \
        --license-endpoint-id "$le_id" \
        --query "status" \
        --output text 2>/dev/null || echo "")
    if [[ "$LE_VPC" == "$VPC_ID" && "$LE_STATUS" == "READY" ]]; then
        EXISTING_LE="$le_id"
        EXISTING_DNS=$(aws deadline get-license-endpoint \
            --region "$REGION" \
            --license-endpoint-id "$le_id" \
            --query "dnsName" \
            --output text 2>/dev/null)
        break
    fi
done

ENDPOINT_ID=""
DNS_NAME=""

if [[ -n "$EXISTING_LE" ]]; then
    log "Reusing existing license endpoint: $EXISTING_LE"
    log "DNS: $EXISTING_DNS"
    ENDPOINT_ID="$EXISTING_LE"
    DNS_NAME="$EXISTING_DNS"
else
    # --- Step 4: Create license endpoint ---
    log "No existing endpoint found. Creating new license endpoint..."

    if ! $YES && ! $DRY_RUN; then
        echo ""
        echo "About to create license endpoint with:"
        echo "  VPC:       $VPC_ID"
        echo "  Subnet:    $SUBNET_ID"
        echo "  SG:        $SG_ID"
        echo "  Region:    $REGION"
        echo ""
        read -rp "Proceed? [y/N] " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Aborted."
    fi

    if $DRY_RUN; then
        log "[DRY-RUN] Would create endpoint and wait for READY"
        ENDPOINT_ID="(dry-run)"
        DNS_NAME="(dry-run)"
    else
        CREATE_OUTPUT=$(aws deadline create-license-endpoint \
            --region "$REGION" \
            --vpc-id "$VPC_ID" \
            --subnet-ids "$SUBNET_ID" \
            --security-group-ids "$SG_ID" \
            --output json) || die "Failed to create license endpoint"

        ENDPOINT_ID=$(echo "$CREATE_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['licenseEndpointId'])")
        log "Created endpoint: $ENDPOINT_ID"

        # Wait for READY
        log "Waiting for READY status..."
        for _attempt in $(seq 1 40); do
            STATUS=$(aws deadline get-license-endpoint \
                --region "$REGION" \
                --license-endpoint-id "$ENDPOINT_ID" \
                --query "status" \
                --output text 2>/dev/null)
            if [[ "$STATUS" == "READY" ]]; then
                log "Endpoint is READY!"
                break
            fi
            if [[ "$STATUS" == "FAILED" ]]; then
                die "Endpoint creation FAILED"
            fi
            sleep 15
        done

        DNS_NAME=$(aws deadline get-license-endpoint \
            --region "$REGION" \
            --license-endpoint-id "$ENDPOINT_ID" \
            --query "dnsName" \
            --output text)
        log "DNS: $DNS_NAME"
    fi
fi

# --- Step 5: Attach metered products ---
log "Attaching metered products: $METERED_PRODUCTS"
for product in $METERED_PRODUCTS; do
    if $DRY_RUN; then
        log "  [DRY-RUN] Would attach: $product"
    else
        aws deadline put-metered-product \
            --region "$REGION" \
            --license-endpoint-id "$ENDPOINT_ID" \
            --product-id "$product" \
            --output json || true
        log "  Attached: $product"
    fi
done

# --- Step 6: Open SG self-ingress for license ports ---
log "Ensuring SG self-ingress on TCP $LICENSE_PORTS..."
EXISTING_RULE=$(aws ec2 describe-security-group-rules \
    --region "$REGION" \
    --filters "Name=group-id,Values=$SG_ID" "Name=is-egress,Values=false" \
    --query "SecurityGroupRules[?IpProtocol=='tcp' && FromPort==\`${LICENSE_PORTS%%-*}\` && ToPort==\`${LICENSE_PORTS##*-}\` && ReferencedGroupInfo.GroupId=='$SG_ID'].SecurityGroupRuleId" \
    --output text 2>/dev/null || echo "")

if [[ -z "$EXISTING_RULE" || "$EXISTING_RULE" == "None" ]]; then
    if $DRY_RUN; then
        log "  [DRY-RUN] Would open TCP $LICENSE_PORTS (self-referencing)"
    else
        aws ec2 authorize-security-group-ingress \
            --region "$REGION" \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port "$LICENSE_PORTS" \
            --source-group "$SG_ID" \
            --output json
        log "  Opened TCP $LICENSE_PORTS (self-referencing)"
    fi
else
    log "  Already open (skipping)"
fi

# --- Step 7: Write DNS to Secrets Manager ---
log "Writing endpoint DNS to Secrets Manager: $SECRET_ID"
if $DRY_RUN; then
    log "  [DRY-RUN] Would write DNS to $SECRET_ID"
else
    aws secretsmanager put-secret-value \
        --region "$REGION" \
        --secret-id "$SECRET_ID" \
        --secret-string "$DNS_NAME" \
        --output json || die "Failed to update secret"
    log "  Updated secret: $SECRET_ID"
fi

# --- Done ---
echo ""
echo "=== UBL Endpoint Ready ==="
echo "Endpoint ID:  $ENDPOINT_ID"
echo "DNS:          $DNS_NAME"
echo "Secret:       $SECRET_ID"
echo "VPC:          $VPC_ID"
echo "Products:     $METERED_PRODUCTS"
echo "SG rule:      $SG_ID TCP $LICENSE_PORTS (self)"
echo ""
echo "Next: Right-click the Infrastructure row in Deadline Monitor -> Start Spot Fleet"

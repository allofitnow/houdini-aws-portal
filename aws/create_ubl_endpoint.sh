#!/usr/bin/env bash
# aws/create_ubl_endpoint.sh
# Create or reuse a Deadline Cloud UBL license endpoint for Houdini workers.
#
# Two modes:
#   1. Direct mode -- supply --vpc-id, --subnet-id, and --sg-id directly.
#      No AWS Portal infrastructure required.
#   2. Portal mode (default) -- auto-discovers the active Portal CloudFormation
#      stack and extracts VPC, subnet, and SG from it.
#
# Either way: creates/reuses the endpoint, attaches SideFX metered products,
# opens worker SG self-ingress on TCP 1715-1717, and writes the endpoint DNS
# to Secrets Manager.
#
# Prerequisites:
#   - AWS CLI configured with deadline:* and ec2:* permissions
#   - In Portal mode: Portal infrastructure started from Deadline Monitor (CF stack CREATE_COMPLETE)
#
# Usage:
#   # Direct mode (no Portal needed):
#   ./aws/create_ubl_endpoint.sh --region us-west-2 \
#       --vpc-id vpc-xxx --subnet-id subnet-xxx --sg-id sg-xxx
#
#   # Portal mode (auto-discover):
#   ./aws/create_ubl_endpoint.sh --region us-west-2            # apply
#   ./aws/create_ubl_endpoint.sh --region us-west-2 --dry-run  # preview only
#   ./aws/create_ubl_endpoint.sh --region us-west-2 --yes      # skip confirmation

set -euo pipefail

# --- Defaults ---
REGION=""
DRY_RUN=false
YES=false
DIRECT_VPC_ID=""
DIRECT_SUBNET_ID=""
DIRECT_SG_ID=""
SECRET_ID="${HOUDINI_LICENSE_ENDPOINT_SECRET_ID:-houdini/license-endpoint-dns}"
METERED_PRODUCTS="houdini-21.0 karma-21.0 mantra-21.0"
LICENSE_PORTS="1715-1717"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)     REGION="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --yes)        YES=true; shift ;;
        --vpc-id)     DIRECT_VPC_ID="$2"; shift 2 ;;
        --subnet-id)  DIRECT_SUBNET_ID="$2"; shift 2 ;;
        --sg-id)      DIRECT_SG_ID="$2"; shift 2 ;;
        --secret-id)  SECRET_ID="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 --region <region> [OPTIONS]"
            echo ""
            echo "Direct mode (no Portal infrastructure needed):"
            echo "  --vpc-id VPC_ID       VPC for the license endpoint"
            echo "  --subnet-id SUBNET_ID Subnet for the license endpoint"
            echo "  --sg-id SG_ID         Security group for the license endpoint"
            echo ""
            echo "Portal mode (auto-discovers Portal stack if above flags omitted):"
            echo "  (no extra flags needed)"
            echo ""
            echo "Common options:"
            echo "  --region REGION       AWS region (required)"
            echo "  --dry-run             Preview changes without applying"
            echo "  --yes                 Skip confirmation prompt"
            echo "  --secret-id SECRET    Secrets Manager secret name (default: houdini/license-endpoint-dns)"
            exit 0
            ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$REGION" ]]; then
    echo "ERROR: --region is required"
    exit 1
fi

# Direct mode requires all three: vpc, subnet, sg
DIRECT_MODE=false
if [[ -n "$DIRECT_VPC_ID" || -n "$DIRECT_SUBNET_ID" || -n "$DIRECT_SG_ID" ]]; then
    if [[ -z "$DIRECT_VPC_ID" || -z "$DIRECT_SUBNET_ID" || -z "$DIRECT_SG_ID" ]]; then
        echo "ERROR: --vpc-id, --subnet-id, and --sg-id must all be provided together"
        exit 1
    fi
    DIRECT_MODE=true
fi

# --- Helpers ---
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# --- Step 1: Resolve VPC, subnet, and security group ---
if $DIRECT_MODE; then
    VPC_ID="$DIRECT_VPC_ID"
    SUBNET_ID="$DIRECT_SUBNET_ID"
    SG_ID="$DIRECT_SG_ID"
    log "Direct mode -- skipping Portal discovery"
    log "VPC: $VPC_ID"
    log "Subnet: $SUBNET_ID"
    log "Worker SG: $SG_ID"
else
    log "Discovering Portal CloudFormation stack in $REGION..."

    PARENT_STACK=""
    STACKS_RAW=$(aws cloudformation describe-stacks \
        --region "$REGION" \
        --query "Stacks[?StackStatus=='CREATE_COMPLETE'].StackName" \
        --output text 2>/dev/null) || die "Failed to list CloudFormation stacks"
    read -r -a STACKS <<< "$STACKS_RAW"

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
        die "No Portal infrastructure stack found in $REGION. Start infrastructure from Deadline Monitor first, or use --vpc-id/--subnet-id/--sg-id for direct mode."
    fi

    log "Found Portal stack: $PARENT_STACK"

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
fi

# --- Step 2: Check for existing license endpoint in this VPC ---
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
    # --- Step 3: Create license endpoint ---
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

# --- Step 4: Attach metered products ---
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

# --- Step 5: Open SG self-ingress for license ports ---
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

# --- Step 6: Write DNS to Secrets Manager ---
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
if $DIRECT_MODE; then
    echo "Next: Workers can now fetch the license endpoint DNS from $SECRET_ID"
else
    echo "Next: Right-click the Infrastructure row in Deadline Monitor -> Start Spot Fleet"
fi

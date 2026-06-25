#!/usr/bin/env bash
# aws/ubl_ctl.sh
# Manage Deadline Cloud UBL license endpoints: list, show, create, remove.
#
# This is the operator-facing CLI for UBL lifecycle management. It wraps
# the Deadline Cloud API (aws deadline ...) with a clean subcommand interface.
#
# No AWS Portal infrastructure required -- all commands work with direct
# VPC/subnet/SG references.
#
# Prerequisites:
#   - AWS CLI configured with deadline:* and ec2:* permissions
#
# Usage:
#   aws/ubl_ctl.sh list    --region us-west-2
#   aws/ubl_ctl.sh show    --region us-west-2 --endpoint-id le-xxx
#   aws/ubl_ctl.sh create  --region us-west-2 \
#       --vpc-id vpc-xxx --subnet-id subnet-xxx --sg-id sg-xxx [--products "houdini-21.0 karma-21.0 mantra-21.0"]
#   aws/ubl_ctl.sh remove  --region us-west-2 --endpoint-id le-xxx
#
# Common flags:
#   --region REGION        AWS region (required)
#   --dry-run              Preview without making changes (list/show always read-only)
#   --yes                  Skip confirmation prompts
#   --output FORMAT        Output format: table (default), json, text

set -euo pipefail

# --- Defaults ---
REGION=""
DRY_RUN=false
YES=false
OUTPUT_FORMAT="table"
SUBCOMMAND=""
ENDPOINT_ID=""
VPC_ID=""
SUBNET_ID=""
SG_ID=""
PRODUCTS="houdini-21.0 karma-21.0 mantra-21.0"
SECRET_ID="${HOUDINI_LICENSE_ENDPOINT_SECRET_ID:-houdini/license-endpoint-dns}"
LICENSE_PORTS="1715-1717"

# --- Helpers ---
log()  { echo "[UBL] $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<USAGE
Usage: aws/ubl_ctl.sh <command> [options]

Commands:
  list      List all UBL license endpoints in a region
  show      Show details of a specific endpoint (DNS, products, SG status)
  create    Create a new license endpoint with metered products
  remove    Delete a license endpoint

Options:
  --region REGION        AWS region (required)
  --endpoint-id ID       License endpoint ID (for show/remove)
  --vpc-id VPC_ID        VPC ID (for create)
  --subnet-id SUBNET_ID  Subnet ID (for create)
  --sg-id SG_ID          Security group ID (for create)
  --products CSV         Space-separated metered products (default: houdini-21.0 karma-21.0 mantra-21.0)
  --secret-id SECRET     Secrets Manager secret name (default: houdini/license-endpoint-dns)
  --dry-run              Preview without changes
  --yes                  Skip confirmation prompts
  --output FORMAT        table (default), json, or text
  -h, --help             Show this help

Examples:
  aws/ubl_ctl.sh list --region us-west-2
  aws/ubl_ctl.sh show --region us-west-2 --endpoint-id le-58eccf4b04cd4f2b818ae3cebb7a56d4
  aws/ubl_ctl.sh create --region us-west-2 \\
      --vpc-id vpc-23b1f65b --subnet-id subnet-xxx --sg-id sg-xxx
  aws/ubl_ctl.sh remove --region us-west-2 --endpoint-id le-xxx --yes
USAGE
}

# --- Parse args ---
if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

SUBCOMMAND="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)       REGION="$2"; shift 2 ;;
        --endpoint-id)  ENDPOINT_ID="$2"; shift 2 ;;
        --vpc-id)       VPC_ID="$2"; shift 2 ;;
        --subnet-id)    SUBNET_ID="$2"; shift 2 ;;
        --sg-id)        SG_ID="$2"; shift 2 ;;
        --products)     PRODUCTS="$2"; shift 2 ;;
        --secret-id)    SECRET_ID="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --yes)          YES=true; shift ;;
        --output)       OUTPUT_FORMAT="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -z "$REGION" ]] && die "--region is required"

# ============================================================================
# list - List all UBL license endpoints
# ============================================================================
cmd_list() {
    log "Listing license endpoints in $REGION..."

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        aws deadline list-license-endpoints \
            --region "$REGION" --output json
        return
    fi

    local raw
    raw=$(aws deadline list-license-endpoints --region "$REGION" --output json)

    if [[ "$OUTPUT_FORMAT" == "text" ]]; then
        echo "$raw" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for ep in data.get('licenseEndpoints', []):
    eid = ep.get('licenseEndpointId', '')
    status = ep.get('status', '')
    vpc = ep.get('vpcId', '')
    print(f'{eid}\t{status}\t{vpc}')
"
        return
    fi

    # table format (default)
    echo "$raw" | python3 -c "
import sys, json
data = json.load(sys.stdin)
eps = data.get('licenseEndpoints', [])
if not eps:
    print('No license endpoints found.')
    sys.exit(0)

# Collect detailed info
rows = []
for ep in eps:
    eid = ep['licenseEndpointId']
    rows.append({
        'id': eid,
        'status': ep.get('status', ''),
        'vpc': ep.get('vpcId', '')
    })

# Print table
hdr = f\"{'Endpoint ID':<42} {'Status':<10} {'VPC ID':<20}\"
print(hdr)
print('-' * len(hdr))
for r in rows:
    print(f\"{r['id']:<42} {r['status']:<10} {r['vpc']:<20}\")
print(f'\nTotal: {len(rows)} endpoint(s)')
"
}

# ============================================================================
# show - Show details of a specific endpoint
# ============================================================================
cmd_show() {
    [[ -z "$ENDPOINT_ID" ]] && die "--endpoint-id is required for 'show'"

    log "Fetching endpoint $ENDPOINT_ID..."

    local details products dns status vpc subnets sgs

    details=$(aws deadline get-license-endpoint \
        --region "$REGION" \
        --license-endpoint-id "$ENDPOINT_ID" \
        --output json)

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        echo "$details"
        return
    fi

    dns=$(echo "$details" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('dnsName','(none)'))")
    status=$(echo "$details" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','(unknown)'))")
    vpc=$(echo "$details" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('vpcId','(none)'))")
    subnets=$(echo "$details" | python3 -c "import sys,json; d=json.load(sys.stdin); print(' '.join(d.get('subnetIds',[])))")
    sgs=$(echo "$details" | python3 -c "import sys,json; d=json.load(sys.stdin); print(' '.join(d.get('securityGroupIds',[])))")

    # Fetch metered products
    products=$(aws deadline list-metered-products \
        --region "$REGION" \
        --license-endpoint-id "$ENDPOINT_ID" \
        --output json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
prods = data.get('meteredProducts', [])
if not prods:
    print('(none)')
else:
    for p in prods:
        print(f\"  {p['productId']:<16} port {p.get('port','?')}\")
" 2>/dev/null || echo "  (unable to fetch)")

    echo ""
    echo "=== UBL License Endpoint: $ENDPOINT_ID ==="
    echo ""
    printf "  %-16s %s\n" "Status:" "$status"
    printf "  %-16s %s\n" "VPC:" "$vpc"
    printf "  %-16s %s\n" "Subnets:" "$subnets"
    printf "  %-16s %s\n" "Security Groups:" "$sgs"
    printf "  %-16s %s\n" "DNS:" "$dns"
    echo ""
    echo "  Metered Products:"
    echo "$products"
    echo ""

    # Check SG self-ingress rule exists
    for sg in $sgs; do
        local rule_exists
        rule_exists=$(aws ec2 describe-security-group-rules \
            --region "$REGION" \
            --filters "Name=group-id,Values=$sg" "Name=is-egress,Values=false" \
            --query "SecurityGroupRules[?IpProtocol=='tcp' && FromPort==\`1715\` && ToPort==\`1717\`].SecurityGroupRuleId" \
            --output text 2>/dev/null || echo "")

        if [[ -n "$rule_exists" && "$rule_exists" != "None" ]]; then
            echo "  SG $sg: TCP 1715-1717 self-ingress: OPEN"
        else
            echo "  SG $sg: TCP 1715-1717 self-ingress: NOT OPEN (workers may fail to get licenses)"
        fi
    done

    # Check Secrets Manager
    local secret_value
    secret_value=$(aws secretsmanager get-secret-value \
        --region "$REGION" \
        --secret-id "$SECRET_ID" \
        --query SecretString --output text 2>/dev/null || echo "(not set)")
    echo ""
    printf "  %-16s %s\n" "Secret ($SECRET_ID):" "$secret_value"
    echo ""
}

# ============================================================================
# create - Create a new license endpoint
# ============================================================================
cmd_create() {
    [[ -z "$VPC_ID" ]] && die "--vpc-id is required for 'create'"
    [[ -z "$SUBNET_ID" ]] && die "--subnet-id is required for 'create'"
    [[ -z "$SG_ID" ]] && die "--sg-id is required for 'create'"

    log "Creating license endpoint in $REGION..."
    echo "  VPC:       $VPC_ID"
    echo "  Subnet:    $SUBNET_ID"
    echo "  SG:        $SG_ID"
    echo "  Products:  $PRODUCTS"
    echo ""

    if ! $YES && ! $DRY_RUN; then
        read -rp "Proceed? [y/N] " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Aborted."
    fi

    if $DRY_RUN; then
        log "[DRY-RUN] Would create endpoint, attach products, open SG, and write secret"
        return
    fi

    # Check for existing endpoint in this VPC
    local existing_le
    existing_le=$(aws deadline list-license-endpoints \
        --region "$REGION" --output json | python3 -c "
import sys, json
data = json.load(sys.stdin)
for ep in data.get('licenseEndpoints', []):
    if ep.get('vpcId') == '$VPC_ID' and ep.get('status') == 'READY':
        print(ep['licenseEndpointId'])
        break
" 2>/dev/null || echo "")

    if [[ -n "$existing_le" ]]; then
        log "Found existing READY endpoint in VPC $VPC_ID: $existing_le"
        log "Reusing. Use 'show' to inspect, or 'remove' then 'create' to recreate."
        ENDPOINT_ID="$existing_le"
        return
    fi

    # Create
    local create_output
    create_output=$(aws deadline create-license-endpoint \
        --region "$REGION" \
        --vpc-id "$VPC_ID" \
        --subnet-ids "$SUBNET_ID" \
        --security-group-ids "$SG_ID" \
        --output json) || die "Failed to create license endpoint"

    ENDPOINT_ID=$(echo "$create_output" | python3 -c "import sys,json; print(json.load(sys.stdin)['licenseEndpointId'])")
    log "Created endpoint: $ENDPOINT_ID"

    # Wait for READY
    log "Waiting for READY status..."
    for _ in $(seq 1 40); do
        local status
        status=$(aws deadline get-license-endpoint \
            --region "$REGION" \
            --license-endpoint-id "$ENDPOINT_ID" \
            --query "status" --output text 2>/dev/null || echo "")
        if [[ "$status" == "READY" ]]; then
            log "Endpoint is READY"
            break
        fi
        if [[ "$status" == "FAILED" || "$status" == "CREATE_FAILED" ]]; then
            die "Endpoint creation FAILED"
        fi
        sleep 15
    done

    # Attach products
    local product
    for product in $PRODUCTS; do
        aws deadline put-metered-product \
            --region "$REGION" \
            --license-endpoint-id "$ENDPOINT_ID" \
            --product-id "$product" \
            --output json 2>/dev/null || true
        log "  Attached: $product"
    done

    # Open SG self-ingress
    local existing_rule
    existing_rule=$(aws ec2 describe-security-group-rules \
        --region "$REGION" \
        --filters "Name=group-id,Values=$SG_ID" "Name=is-egress,Values=false" \
        --query "SecurityGroupRules[?IpProtocol=='tcp' && FromPort==\`1715\` && ToPort==\`1717\`].SecurityGroupRuleId" \
        --output text 2>/dev/null || echo "")

    if [[ -z "$existing_rule" || "$existing_rule" == "None" ]]; then
        aws ec2 authorize-security-group-ingress \
            --region "$REGION" \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port "$LICENSE_PORTS" \
            --source-group "$SG_ID" \
            --output json 2>/dev/null || true
        log "  Opened TCP 1715-1717 (self-referencing) on $SG_ID"
    else
        log "  TCP 1715-1717 already open on $SG_ID"
    fi

    # Write DNS to Secrets Manager
    local dns_name
    dns_name=$(aws deadline get-license-endpoint \
        --region "$REGION" \
        --license-endpoint-id "$ENDPOINT_ID" \
        --query "dnsName" --output text)

    aws secretsmanager put-secret-value \
        --region "$REGION" \
        --secret-id "$SECRET_ID" \
        --secret-string "$dns_name" \
        --output json >/dev/null || die "Failed to update secret"
    log "  Updated secret: $SECRET_ID"

    echo ""
    echo "=== UBL Endpoint Ready ==="
    printf "  %-16s %s\n" "Endpoint ID:" "$ENDPOINT_ID"
    printf "  %-16s %s\n" "DNS:" "$dns_name"
    printf "  %-16s %s\n" "Secret:" "$SECRET_ID"
    printf "  %-16s %s\n" "VPC:" "$VPC_ID"
}

# ============================================================================
# remove - Delete a license endpoint
# ============================================================================
cmd_remove() {
    [[ -z "$ENDPOINT_ID" ]] && die "--endpoint-id is required for 'remove'"

    local details dns vpc status
    details=$(aws deadline get-license-endpoint \
        --region "$REGION" \
        --license-endpoint-id "$ENDPOINT_ID" \
        --output json 2>/dev/null) || die "Endpoint $ENDPOINT_ID not found"

    dns=$(echo "$details" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('dnsName','(none)'))")
    vpc=$(echo "$details" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('vpcId','(none)'))")
    status=$(echo "$details" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','(unknown)'))")

    echo "Endpoint to remove:"
    printf "  %-16s %s\n" "ID:" "$ENDPOINT_ID"
    printf "  %-16s %s\n" "Status:" "$status"
    printf "  %-16s %s\n" "VPC:" "$vpc"
    printf "  %-16s %s\n" "DNS:" "$dns"
    echo ""

    if ! $YES && ! $DRY_RUN; then
        read -rp "Delete this endpoint? This cannot be undone. [y/N] " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Aborted."
    fi

    if $DRY_RUN; then
        log "[DRY-RUN] Would delete endpoint $ENDPOINT_ID"
        return
    fi

    # First remove all metered products (AWS requires empty endpoint before delete)
    log "Removing metered products..."
    local products_raw product_ids
    products_raw=$(aws deadline list-metered-products \
        --region "$REGION" \
        --license-endpoint-id "$ENDPOINT_ID" \
        --output json 2>/dev/null || echo '{"meteredProducts":[]}')

    product_ids=$(echo "$products_raw" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for p in data.get('meteredProducts', []):
    print(p['productId'])
")

    for pid in $product_ids; do
        aws deadline delete-metered-product \
            --region "$REGION" \
            --license-endpoint-id "$ENDPOINT_ID" \
            --product-id "$pid" 2>/dev/null || true
        log "  Removed product: $pid"
    done

    # Delete the endpoint
    aws deadline delete-license-endpoint \
        --region "$REGION" \
        --license-endpoint-id "$ENDPOINT_ID" \
        --output json 2>/dev/null || die "Failed to delete endpoint"

    log "Deleted endpoint: $ENDPOINT_ID"

    # Clear the secret if it contained this endpoint's DNS
    local current_secret
    current_secret=$(aws secretsmanager get-secret-value \
        --region "$REGION" \
        --secret-id "$SECRET_ID" \
        --query SecretString --output text 2>/dev/null || echo "")

    if [[ "$current_secret" == "$dns" ]]; then
        log "Clearing stale secret ($SECRET_ID contained this endpoint's DNS)"
        aws secretsmanager put-secret-value \
            --region "$REGION" \
            --secret-id "$SECRET_ID" \
            --secret-string "PENDING" \
            --output json >/dev/null 2>/dev/null || true
        log "  Secret set to PENDING"
    fi
}

# ============================================================================
# Dispatch
# ============================================================================
case "$SUBCOMMAND" in
    list)    cmd_list ;;
    show)    cmd_show ;;
    create)  cmd_create ;;
    remove)  cmd_remove ;;
    -h|--help) usage ;;
    *)       die "Unknown command: '$SUBCOMMAND'. Use --help for usage." ;;
esac

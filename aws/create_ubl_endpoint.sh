#!/usr/bin/env bash
# create_ubl_endpoint.sh
# Create or reuse the Deadline Cloud UBL license endpoint for the active AWS Portal infrastructure.
# Run this after AWS Portal Start Infrastructure reaches CREATE_COMPLETE and before Start Spot Fleet.

set -euo pipefail

REGION="${REGION:-${AWS_REGION:-us-west-2}}"
STACK_NAME="${STACK_NAME:-}"
VPC_ID="${VPC_ID:-}"
SUBNET_ID="${SUBNET_ID:-}"
SG_ID="${SG_ID:-}"
SECRET_ID="${HOUDINI_LICENSE_ENDPOINT_SECRET_ID:-houdini/license-endpoint-dns}"
PRODUCTS=("houdini-21.0" "karma-21.0" "mantra-21.0")
COMMAND_MODE="dry-run"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-900}"
WAIT_INTERVAL_SECONDS="${WAIT_INTERVAL_SECONDS:-15}"

usage() {
    cat >&2 <<USAGE
Usage: $0 [options] [--yes|--dry-run]

Creates or reuses the Deadline Cloud license endpoint for the current AWS Portal stack,
attaches SideFX metered products, opens worker SG self-ingress on TCP 1715-1717,
and writes the endpoint DNS to Secrets Manager. Defaults to dry-run.

Options:
  --region REGION                 AWS region (default: REGION/AWS_REGION/us-west-2)
  --stack-name STACK_NAME         AWS Portal parent stack name; auto-discovers newest active stack if omitted
  --vpc-id VPC_ID                 Override discovered Portal VPC
  --subnet-id SUBNET_ID           Override discovered endpoint subnet; defaults to Portal PublicSubnet
  --sg-id SG_ID                   Override discovered endpoint/worker SG; defaults to ReverseSlaveSG
  --secret-id SECRET_ID           Secrets Manager secret for endpoint DNS (default: houdini/license-endpoint-dns)
  --products CSV                  Metered products to attach (default: houdini-21.0,karma-21.0,mantra-21.0)
  --wait-timeout-seconds SECONDS  Endpoint READY timeout (default: 900)
  --yes                           Apply changes
  --dry-run                       Print planned changes only (default)
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region|--aws-region)
            REGION="$2"
            shift 2
            ;;
        --stack-name)
            STACK_NAME="$2"
            shift 2
            ;;
        --vpc-id)
            VPC_ID="$2"
            shift 2
            ;;
        --subnet-id)
            SUBNET_ID="$2"
            shift 2
            ;;
        --sg-id|--security-group-id)
            SG_ID="$2"
            shift 2
            ;;
        --secret-id)
            SECRET_ID="$2"
            shift 2
            ;;
        --products)
            IFS=',' read -r -a PRODUCTS <<< "$2"
            shift 2
            ;;
        --wait-timeout-seconds)
            WAIT_TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        --yes)
            COMMAND_MODE="apply"
            shift
            ;;
        --dry-run)
            COMMAND_MODE="dry-run"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument '$1'" >&2
            usage
            exit 1
            ;;
    esac
done

run_or_print() {
    if [[ "$COMMAND_MODE" == "apply" ]]; then
        "$@"
    else
        printf 'DRY-RUN:'
        printf ' %q' "$@"
        printf '\n'
    fi
}

aws_text() {
    aws "$@" --output text
}

aws_json() {
    aws "$@" --output json
}

discover_stack_name() {
    local stack_names
    local stack_name_array
    local stack_name
    local vpc_id

    stack_names=$(aws_text cloudformation list-stacks \
        --region "$REGION" \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
        --query "reverse(sort_by(StackSummaries[?starts_with(StackName,'stack')], &CreationTime))[].StackName")

    read -r -a stack_name_array <<< "$stack_names"
    for stack_name in "${stack_name_array[@]}"; do
        vpc_id=$(aws_text cloudformation describe-stack-resources \
            --region "$REGION" \
            --stack-name "$stack_name" \
            --query "StackResources[?LogicalResourceId=='ReverseDashVPC'].PhysicalResourceId | [0]" 2>/dev/null || true)

        if [[ -n "$vpc_id" && "$vpc_id" != "None" ]]; then
            printf '%s\n' "$stack_name"
            return 0
        fi
    done
}

stack_resource() {
    local logical_id="$1"
    aws_text cloudformation describe-stack-resources \
        --region "$REGION" \
        --stack-name "$STACK_NAME" \
        --query "StackResources[?LogicalResourceId=='${logical_id}'].PhysicalResourceId | [0]"
}

existing_license_endpoint_for_vpc() {
    aws_text deadline list-license-endpoints \
        --region "$REGION" \
        --query "licenseEndpoints[?vpcId=='${VPC_ID}'].licenseEndpointId | [0]" 2>/dev/null || true
}

wait_for_endpoint_ready() {
    local endpoint_id="$1"
    local elapsed=0
    local status=""
    local status_message=""

    while (( elapsed <= WAIT_TIMEOUT_SECONDS )); do
        status=$(aws_text deadline get-license-endpoint \
            --region "$REGION" \
            --license-endpoint-id "$endpoint_id" \
            --query "status")
        status_message=$(aws_text deadline get-license-endpoint \
            --region "$REGION" \
            --license-endpoint-id "$endpoint_id" \
            --query "statusMessage" 2>/dev/null || true)

        echo "License endpoint ${endpoint_id} status: ${status} (${status_message})"
        if [[ "$status" == "READY" ]]; then
            return 0
        fi
        if [[ "$status" == "CREATE_FAILED" || "$status" == "DELETE_FAILED" ]]; then
            return 1
        fi

        sleep "$WAIT_INTERVAL_SECONDS"
        elapsed=$((elapsed + WAIT_INTERVAL_SECONDS))
    done

    echo "ERROR: License endpoint ${endpoint_id} did not reach READY within ${WAIT_TIMEOUT_SECONDS}s." >&2
    return 1
}

ensure_secret_value() {
    local dns_name="$1"

    if [[ "$COMMAND_MODE" == "dry-run" ]]; then
        echo "DRY-RUN: would create/update Secrets Manager secret ${SECRET_ID} with ${dns_name}"
        return
    fi

    if aws secretsmanager describe-secret --region "$REGION" --secret-id "$SECRET_ID" >/dev/null 2>&1; then
        aws secretsmanager put-secret-value \
            --region "$REGION" \
            --secret-id "$SECRET_ID" \
            --secret-string "$dns_name" \
            --output text >/dev/null
    else
        aws secretsmanager create-secret \
            --region "$REGION" \
            --name "$SECRET_ID" \
            --secret-string "$dns_name" \
            --output text >/dev/null
    fi
}

ensure_self_ingress() {
    if [[ "$COMMAND_MODE" == "dry-run" ]]; then
        echo "DRY-RUN: would authorize ${SG_ID} self-ingress TCP 1715-1717"
        return
    fi

    if aws ec2 authorize-security-group-ingress \
        --region "$REGION" \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 1715-1717 \
        --source-group "$SG_ID" \
        --output text >/tmp/create_ubl_endpoint_sg.out 2>/tmp/create_ubl_endpoint_sg.err; then
        echo "Authorized ${SG_ID} self-ingress TCP 1715-1717."
        return
    fi

    if grep -q "InvalidPermission.Duplicate" /tmp/create_ubl_endpoint_sg.err; then
        echo "Security group self-ingress TCP 1715-1717 already exists on ${SG_ID}."
        return
    fi

    cat /tmp/create_ubl_endpoint_sg.err >&2
    return 1
}

if [[ -z "$STACK_NAME" ]]; then
    STACK_NAME=$(discover_stack_name)
fi

if [[ -z "$STACK_NAME" || "$STACK_NAME" == "None" ]]; then
    echo "ERROR: No active AWS Portal stack found in ${REGION}. Run Start Infrastructure first." >&2
    exit 1
fi

if [[ -z "$VPC_ID" ]]; then
    VPC_ID=$(stack_resource ReverseDashVPC)
fi
if [[ -z "$SUBNET_ID" ]]; then
    SUBNET_ID=$(stack_resource PublicSubnet)
fi
if [[ -z "$SG_ID" ]]; then
    SG_ID=$(stack_resource ReverseSlaveSG)
fi

for required in STACK_NAME VPC_ID SUBNET_ID SG_ID SECRET_ID; do
    if [[ -z "${!required}" || "${!required}" == "None" ]]; then
        echo "ERROR: Missing required value ${required}." >&2
        exit 1
    fi
done

cat <<SUMMARY
=== Deadline Cloud UBL endpoint setup (${COMMAND_MODE}) ===
Region:         ${REGION}
Portal stack:   ${STACK_NAME}
VPC:            ${VPC_ID}
Endpoint subnet:${SUBNET_ID}
Endpoint SG:    ${SG_ID}
Secret ID:      ${SECRET_ID}
Products:       ${PRODUCTS[*]}
SUMMARY

license_endpoint_id=$(existing_license_endpoint_for_vpc)

if [[ -z "$license_endpoint_id" || "$license_endpoint_id" == "None" ]]; then
    if [[ "$COMMAND_MODE" == "dry-run" ]]; then
        echo "DRY-RUN: would create Deadline Cloud license endpoint in ${VPC_ID}"
        license_endpoint_id="<new-license-endpoint-id>"
    else
        license_endpoint_id=$(aws_text deadline create-license-endpoint \
            --region "$REGION" \
            --vpc-id "$VPC_ID" \
            --subnet-ids "$SUBNET_ID" \
            --security-group-ids "$SG_ID" \
            --query "licenseEndpointId")
        echo "Created Deadline Cloud license endpoint: ${license_endpoint_id}"
        wait_for_endpoint_ready "$license_endpoint_id"
    fi
else
    echo "Reusing existing Deadline Cloud license endpoint in ${VPC_ID}: ${license_endpoint_id}"
    if [[ "$COMMAND_MODE" == "apply" ]]; then
        wait_for_endpoint_ready "$license_endpoint_id"
    fi
fi

for product_id in "${PRODUCTS[@]}"; do
    [[ -n "$product_id" ]] || continue
    run_or_print aws deadline put-metered-product \
        --region "$REGION" \
        --license-endpoint-id "$license_endpoint_id" \
        --product-id "$product_id"
done

ensure_self_ingress

if [[ "$COMMAND_MODE" == "apply" ]]; then
    dns_name=$(aws_text deadline get-license-endpoint \
        --region "$REGION" \
        --license-endpoint-id "$license_endpoint_id" \
        --query "dnsName")
else
    dns_name="<license-endpoint-dns>"
fi

ensure_secret_value "$dns_name"

echo ""
echo "License endpoint ID: ${license_endpoint_id}"
echo "License endpoint DNS: ${dns_name}"

if [[ "$COMMAND_MODE" == "apply" ]]; then
    echo ""
    echo "Attached metered products:"
    aws deadline list-metered-products \
        --region "$REGION" \
        --license-endpoint-id "$license_endpoint_id" \
        --output table
fi

echo ""
echo "Next: use AWS Portal → right-click completed infrastructure → Start Spot Fleet."

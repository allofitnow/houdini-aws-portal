#!/usr/bin/env bash
# aws/prepare_portal_region.sh — Portal region preparation: main orchestrator
# Purpose: Validate that an AWS region has all prerequisites for launching a
#          Deadline Portal worker fleet (Portal stack, AMI, UBL endpoint/secret).
# Preconditions: aws CLI, jq installed; valid AWS credentials configured.

set -euo pipefail

# ── Resolve script directory for library sourcing ─────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source libraries ──────────────────────────────────────────────────────────
# shellcheck source=lib/state.sh
source "${SCRIPT_DIR}/lib/state.sh"
# shellcheck source=lib/fsm_labels.sh
source "${SCRIPT_DIR}/lib/fsm_labels.sh"
# shellcheck source=lib/issue_log.sh
source "${SCRIPT_DIR}/lib/issue_log.sh"
# shellcheck source=lib/portal_discovery.sh
source "${SCRIPT_DIR}/lib/portal_discovery.sh"
# shellcheck source=lib/ami_region.sh
source "${SCRIPT_DIR}/lib/ami_region.sh"
# shellcheck source=lib/ubl_check.sh
source "${SCRIPT_DIR}/lib/ubl_check.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
DEFAULT_SOURCE_AMI="ami-0f70342f66dc80ddb"
DEFAULT_SOURCE_REGION="us-west-2"

# ── Temp file cleanup ─────────────────────────────────────────────────────────
declare -a _TMP_FILES=()
_cleanup() {
    local f
    for f in "${_TMP_FILES[@]+"${_TMP_FILES[@]}"}"; do
        rm -f "$f"
    done
}
trap _cleanup EXIT

# Create a temp file and register it for cleanup.
_make_temp() {
    local t
    t=$(mktemp)
    _TMP_FILES+=("$t")
    echo "$t"
}

# ── Dependency check ──────────────────────────────────────────────────────────
_check_deps() {
    local missing=0
    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq is not installed" >&2
        missing=1
    fi
    if ! command -v aws &>/dev/null; then
        echo "ERROR: aws CLI is not installed" >&2
        missing=1
    fi
    if (( missing )); then
        exit 2
    fi
}

# ── Main function ─────────────────────────────────────────────────────────────
main() {
    # ── CLI parsing ───────────────────────────────────────────────────────────
    local REGION=""
    local AMI_NAME=""
    local SOURCE_AMI=""
    local SOURCE_REGION=""
    local STACK_NAME=""
    local DRY_RUN=0
    local AUTO_YES=0
    local JSON_OUTPUT=0
    local WORKFLOW_ISSUE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --region)
                REGION="$2"
                shift 2
                ;;
            --ami-name)
                AMI_NAME="$2"
                shift 2
                ;;
            --source-ami)
                SOURCE_AMI="$2"
                shift 2
                ;;
            --source-region)
                SOURCE_REGION="$2"
                shift 2
                ;;
            --stack-name)
                STACK_NAME="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --yes)
                AUTO_YES=1
                shift
                ;;
            --json)
                JSON_OUTPUT=1
                shift
                ;;
            --workflow-issue)
                WORKFLOW_ISSUE="$2"
                shift 2
                ;;
            *)
                echo "ERROR: unknown argument: $1" >&2
                exit 1
                ;;
        esac
    done

    # Apply defaults
    [[ -z "$SOURCE_AMI" ]] && SOURCE_AMI="$DEFAULT_SOURCE_AMI"
    [[ -z "$SOURCE_REGION" ]] && SOURCE_REGION="$DEFAULT_SOURCE_REGION"

    # Validate required args
    if [[ -z "$REGION" ]]; then
        echo "ERROR: --region is required" >&2
        exit 1
    fi

    # ── Dry-run: print expanded args and exit ─────────────────────────────────
    if (( DRY_RUN )); then
        echo "Region:         $REGION"
        echo "AMI name:       ${AMI_NAME:-not specified}"
        echo "Source AMI:     $SOURCE_AMI"
        echo "Source region:  $SOURCE_REGION"
        echo "Stack name:     ${STACK_NAME:-auto-discover}"
        echo "Apply (--yes):  $AUTO_YES"
        echo "JSON output:    $JSON_OUTPUT"
        echo "Workflow issue: ${WORKFLOW_ISSUE:-none}"
        echo ""
        echo "Would check:"
        echo "  1. Portal CloudFormation stack discovery in $REGION"
        echo "  2. Gateway instance state (running/stopped)"
        echo "  3. Worker subnet IDs and ReverseSlaveSG existence"
        echo "  4. AMI $SOURCE_AMI availability in $REGION (source: $SOURCE_REGION)"
        echo "  5. UBL endpoint and Secrets Manager secret validation"
        exit 0
    fi

    # ── Dependency check (after dry-run so dry-run works without deps) ────────
    _check_deps

    # ── Step 8a: GitLab workflow init (if --workflow-issue) ───────────────────
    if [[ -n "$WORKFLOW_ISSUE" ]]; then
        echo "Initializing workflow state for issue #${WORKFLOW_ISSUE}..." >&2
        state_init "$WORKFLOW_ISSUE" "REGION_SELECTED" || {
            echo "WARNING: state_init failed for issue #${WORKFLOW_ISSUE}" >&2
        }
    fi

    # ── Step 2: Portal stack discovery ────────────────────────────────────────
    echo "Discovering Portal stack in $REGION..." >&2

    local DISCOVERY_FILE
    DISCOVERY_FILE=$(_make_temp)

    local discovery_args=(--region "$REGION")
    [[ -n "$STACK_NAME" ]] && discovery_args+=(--stack-name "$STACK_NAME")

    if ! query_portal_discovery "${discovery_args[@]}" > "$DISCOVERY_FILE"; then
        echo "ERROR: Portal stack discovery failed in $REGION" >&2

        if [[ -n "$WORKFLOW_ISSUE" ]]; then
            issue_update_next_action "$WORKFLOW_ISSUE" \
                "Deploy AWS Portal in $REGION first" || true
            issue_log "$WORKFLOW_ISSUE" "Portal region preparation failed: no stack found" || true
        fi

        if (( JSON_OUTPUT )); then
            _output_json_error "portal_stack_missing" \
                "Deploy AWS Portal in $REGION first"
        fi
        exit 1
    fi

    # Parse TSV discovery output into associative arrays
    # TSV columns: REGION  STACK_NAME  STACK_STATUS  VALUE  RESOURCE_KEY
    local -A DISC=()
    local _d_region _d_stack _d_status _d_value _d_key
    while IFS=$'\t' read -r _d_region _d_stack _d_status _d_value _d_key; do
        [[ "$_d_region" == "REGION" ]] && continue
        DISC["stack_name"]="$_d_stack"
        DISC["stack_status"]="$_d_status"
        case "$_d_key" in
            vpc_id)               DISC["vpc_id"]="$_d_value" ;;
            gateway_instance_id)  DISC["gateway_id"]="$_d_value" ;;
            gateway_state)        DISC["gateway_state"]="$_d_value" ;;
            worker_subnet_ids)    DISC["worker_subnet_ids"]="$_d_value" ;;
            reverse_slave_sg_id)  DISC["reverse_slave_sg"]="$_d_value" ;;
            portal_client_bucket) DISC["portal_bucket"]="$_d_value" ;;
            gateway_cert_path)    DISC["gateway_cert"]="$_d_value" ;;
        esac
    done < "$DISCOVERY_FILE"

    # Validate stack status is CREATE_COMPLETE
    if [[ "${DISC[stack_status]:-}" != "CREATE_COMPLETE" ]]; then
        echo "ERROR: Portal stack '${DISC[stack_name]:-unknown}' status is '${DISC[stack_status]:-unknown}', expected CREATE_COMPLETE" >&2

        if [[ -n "$WORKFLOW_ISSUE" ]]; then
            issue_update_next_action "$WORKFLOW_ISSUE" \
                "Deploy AWS Portal in $REGION first" || true
            issue_log "$WORKFLOW_ISSUE" "Portal stack not CREATE_COMPLETE in $REGION" || true
        fi

        if (( JSON_OUTPUT )); then
            _output_json_error "portal_stack_invalid" \
                "Deploy AWS Portal in $REGION first"
        fi
        exit 1
    fi

    echo "  Stack: ${DISC[stack_name]} (CREATE_COMPLETE)" >&2
    echo "  VPC:   ${DISC[vpc_id]:-not found}" >&2

    # ── Step 3: Gateway state check ───────────────────────────────────────────
    local GATEWAY_STATE="${DISC[gateway_state]:-unknown}"
    local GATEWAY_ID="${DISC[gateway_id]:-}"

    if [[ "$GATEWAY_STATE" != "running" ]]; then
        echo "WARNING: Gateway ${GATEWAY_ID} is ${GATEWAY_STATE} (may be stopped to save costs)" >&2
    else
        echo "  Gateway: ${GATEWAY_ID} (${GATEWAY_STATE})" >&2
    fi

    # ── Step 4: Worker subnet and ReverseSlaveSG check ────────────────────────
    local WORKER_SUBNETS="${DISC[worker_subnet_ids]:-}"
    local REVERSE_SLAVE_SG="${DISC[reverse_slave_sg]:-}"

    # Count worker subnets
    local -a SUBNET_ARRAY=()
    if [[ -n "$WORKER_SUBNETS" ]]; then
        IFS=',' read -ra SUBNET_ARRAY <<< "$WORKER_SUBNETS"
    fi
    local SUBNET_COUNT=${#SUBNET_ARRAY[@]}

    if (( SUBNET_COUNT == 0 )); then
        echo "ERROR: No worker subnet IDs found in Portal stack" >&2

        if [[ -n "$WORKFLOW_ISSUE" ]]; then
            issue_update_next_action "$WORKFLOW_ISSUE" \
                "Portal stack incomplete — check CloudFormation resources" || true
            issue_log "$WORKFLOW_ISSUE" "Portal region preparation failed: no worker subnets" || true
        fi

        if (( JSON_OUTPUT )); then
            _output_json_error "subnets_missing" \
                "Portal stack incomplete — check CloudFormation resources"
        fi
        exit 1
    fi

    if [[ -z "$REVERSE_SLAVE_SG" ]]; then
        echo "ERROR: ReverseSlaveSG not found in Portal stack" >&2

        if [[ -n "$WORKFLOW_ISSUE" ]]; then
            issue_update_next_action "$WORKFLOW_ISSUE" \
                "Portal stack incomplete — check CloudFormation resources" || true
            issue_log "$WORKFLOW_ISSUE" "Portal region preparation failed: no ReverseSlaveSG" || true
        fi

        if (( JSON_OUTPUT )); then
            _output_json_error "sg_missing" \
                "Portal stack incomplete — check CloudFormation resources"
        fi
        exit 1
    fi

    echo "  Worker subnets: ${SUBNET_COUNT} (${WORKER_SUBNETS})" >&2
    echo "  ReverseSlaveSG: ${REVERSE_SLAVE_SG}" >&2

    # ── Step 5: AMI regional availability check ──────────────────────────────
    echo "Checking AMI availability in $REGION..." >&2

    local AMI_FILE
    AMI_FILE=$(_make_temp)

    local ami_args=(--region "$REGION" --source-ami "$SOURCE_AMI" --source-region "$SOURCE_REGION")
    if (( AUTO_YES )); then
        ami_args+=(--yes)
    fi

    local AMI_STATUS="exists"
    local AMI_ID="$SOURCE_AMI"

    if ! query_ami_region "${ami_args[@]}" > "$AMI_FILE"; then
        # query_ami_region returns non-zero on copy_failed or other hard errors
        # Check the output to see if it was a copy failure
        local _ami_region _ami_id _ami_status
        while IFS=$'\t' read -r _ami_region _ami_id _ami_status; do
            [[ "$_ami_region" == "REGION" ]] && continue
            AMI_STATUS="$_ami_status"
            AMI_ID="$_ami_id"
        done < "$AMI_FILE"

        if [[ "$AMI_STATUS" == "copy_failed" ]]; then
            echo "ERROR: AMI copy failed" >&2

            if [[ -n "$WORKFLOW_ISSUE" ]]; then
                issue_update_next_action "$WORKFLOW_ISSUE" \
                    "AMI copy failed — investigate AMI $SOURCE_AMI in $SOURCE_REGION" || true
                issue_log "$WORKFLOW_ISSUE" "AMI copy failed for $SOURCE_AMI to $REGION" || true
            fi

            if (( JSON_OUTPUT )); then
                _output_json_error "ami_copy_failed" \
                    "AMI copy failed — investigate AMI $SOURCE_AMI in $SOURCE_REGION"
            fi
            exit 1
        fi
    else
        # Parse successful AMI check output
        local _ami_region _ami_id _ami_status
        while IFS=$'\t' read -r _ami_region _ami_id _ami_status; do
            [[ "$_ami_region" == "REGION" ]] && continue
            AMI_STATUS="$_ami_status"
            AMI_ID="$_ami_id"
        done < "$AMI_FILE"
    fi

    # Normalize AMI status for reporting
    local AMI_DISPLAY_STATUS="$AMI_STATUS"
    case "$AMI_STATUS" in
        exists|copied_ok)
            AMI_DISPLAY_STATUS="exists"
            echo "  AMI: ${AMI_ID} (exists)" >&2
            ;;
        needs_copy_from:*)
            echo "WARNING: AMI needs copy from ${SOURCE_REGION}. Use --yes to copy." >&2
            ;;
        copying)
            # shellcheck disable=SC2034
            AMI_DISPLAY_STATUS="copying"
            echo "  AMI: copy in progress" >&2
            ;;
        *)
            echo "  AMI status: $AMI_STATUS" >&2
            ;;
    esac

    # ── Step 8b: GitLab workflow — AMI_READY transition ──────────────────────
    if [[ -n "$WORKFLOW_ISSUE" ]]; then
        case "$AMI_STATUS" in
            exists|copied_ok)
                fsm_transition "$WORKFLOW_ISSUE" "AMI_READY" || {
                    echo "WARNING: fsm_transition to AMI_READY failed" >&2
                }
                ;;
        esac
    fi

    # ── Step 8c: GitLab workflow — PORTAL_INFRA_READY transition ─────────────
    if [[ -n "$WORKFLOW_ISSUE" ]]; then
        fsm_transition "$WORKFLOW_ISSUE" "PORTAL_INFRA_READY" || {
            echo "WARNING: fsm_transition to PORTAL_INFRA_READY failed" >&2
        }
    fi

    # ── Step 6: UBL endpoint and secret check ────────────────────────────────
    echo "Checking UBL endpoint and secret..." >&2

    local UBL_FILE
    UBL_FILE=$(_make_temp)

    local ubl_args=(--region "$REGION")
    if [[ -n "${DISC[vpc_id]:-}" ]]; then
        ubl_args+=(--vpc-id "${DISC[vpc_id]}")
    fi
    if (( AUTO_YES )); then
        ubl_args+=(--yes)
    fi

    if ! query_ubl_check "${ubl_args[@]}" > "$UBL_FILE"; then
        echo "WARNING: UBL check encountered errors" >&2
    fi

    # Parse UBL check TSV output
    # Columns: REGION  CHECK_NAME  VALUE  STATUS  RESOURCE_KEY
    local UBL_ENDPOINT_STATUS="not_found"
    local UBL_ENDPOINT_ID=""
    local UBL_ENDPOINT_DNS=""
    local UBL_SECRET_STATUS="missing"
    local UBL_SECRET_NAME="houdini/license-endpoint-dns"
    local UBL_SECRET_MATCH="no_secret"
    local UBL_SECRET_FRESH="no_secret"

    local _u_region _u_check _u_value _u_status _u_key
    while IFS=$'\t' read -r _u_region _u_check _u_value _u_status _u_key; do
        [[ "$_u_region" == "REGION" ]] && continue
        case "$_u_check" in
            ubl_endpoint)
                UBL_ENDPOINT_STATUS="$_u_status"
                UBL_ENDPOINT_ID="$_u_value"
                ;;
            ubl_dns)
                # shellcheck disable=SC2034
                UBL_ENDPOINT_DNS="$_u_value"
                ;;
            ubl_secret)
                UBL_SECRET_STATUS="$_u_status"
                ;;
            ubl_secret_match)
                UBL_SECRET_MATCH="$_u_status"
                ;;
            ubl_secret_fresh)
                UBL_SECRET_FRESH="$_u_status"
                ;;
        esac
    done < "$UBL_FILE"

    if [[ "$UBL_ENDPOINT_STATUS" == "not_found" ]]; then
        echo "WARNING: UBL endpoint not found in $REGION (requires Deadline Cloud setup)" >&2
    else
        echo "  UBL endpoint: ${UBL_ENDPOINT_ID} (${UBL_ENDPOINT_STATUS})" >&2
    fi

    echo "  UBL secret: ${UBL_SECRET_NAME} (${UBL_SECRET_STATUS}, match=${UBL_SECRET_MATCH})" >&2

    # ── Step 8d: GitLab workflow — UBL_READY transition ──────────────────────
    local UBL_READY=0
    if [[ "$UBL_ENDPOINT_STATUS" == "ready" ]] && [[ "$UBL_SECRET_MATCH" == "match" ]]; then
        UBL_READY=1
    fi

    if [[ -n "$WORKFLOW_ISSUE" ]] && (( UBL_READY )); then
        fsm_transition "$WORKFLOW_ISSUE" "UBL_READY" || {
            echo "WARNING: fsm_transition to UBL_READY failed" >&2
        }
    fi

    # ── Step 7: Determine overall readiness and next action ───────────────────

    # Compute readiness flags
    local PORTAL_READY=1     # Already validated above (exit 1 if not)
    local INFRA_READY=1      # Already validated (subnets + SG exist)
    local AMI_READY=0
    local OVERALL_READY=0

    case "$AMI_STATUS" in
        exists|copied_ok) AMI_READY=1 ;;
    esac

    # Overall ready: portal stack OK, infra OK, AMI exists, UBL endpoint ready or acceptable
    if (( AMI_READY )) && (( UBL_READY )); then
        OVERALL_READY=1
    fi

    # Determine next action (decision tree from spec)
    local NEXT_ACTION=""
    if ! (( PORTAL_READY )); then
        NEXT_ACTION="Deploy AWS Portal in $REGION first"
    elif ! (( INFRA_READY )); then
        NEXT_ACTION="Portal stack incomplete — check CloudFormation resources"
    elif ! (( AMI_READY )); then
        NEXT_ACTION="Copy AMI to $REGION with --yes, or run again with --yes"
    elif [[ "$UBL_ENDPOINT_STATUS" == "not_found" ]]; then
        NEXT_ACTION="Set up UBL endpoint in $REGION before launching workers"
    elif ! (( UBL_READY )); then
        NEXT_ACTION="Fix UBL secret in $REGION before launching workers"
    else
        NEXT_ACTION="Region $REGION is ready. Run launch_portal_worker_fleet --region $REGION"
    fi

    # ── Output ────────────────────────────────────────────────────────────────
    if (( JSON_OUTPUT )); then
        _output_json
    else
        _output_human
    fi

    # ── Step 8e-8h: GitLab workflow final updates ────────────────────────────
    if [[ -n "$WORKFLOW_ISSUE" ]]; then
        _update_workflow_issue
    fi
}

# ── JSON output ───────────────────────────────────────────────────────────────
_output_json() {
    local _timestamp
    _timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Subnet IDs array
    local _subnets_json
    if (( ${#SUBNET_ARRAY[@]} > 0 )); then
        _subnets_json=$(printf '%s\n' "${SUBNET_ARRAY[@]}" | jq -R . | jq -s .)
    else
        _subnets_json="[]"
    fi

    # AMI status for JSON
    local _ami_json_status
    case "$AMI_STATUS" in
        exists|copied_ok) _ami_json_status="exists" ;;
        needs_copy_from:*) _ami_json_status="needs_copy" ;;
        copying) _ami_json_status="copying" ;;
        copy_failed) _ami_json_status="copy_failed" ;;
        *) _ami_json_status="$AMI_STATUS" ;;
    esac

    # UBL endpoint status for JSON
    local _ubl_endpoint_json_status="$UBL_ENDPOINT_STATUS"
    if [[ "$UBL_ENDPOINT_STATUS" == "ready" ]]; then
        _ubl_endpoint_json_status="ready"
    fi

    # UBL secret match for JSON
    local _ubl_secret_json_status="$UBL_SECRET_MATCH"
    local _ubl_secret_fresh="false"
    if [[ "$UBL_SECRET_FRESH" == "fresh" ]]; then
        _ubl_secret_fresh="true"
    fi

    # Portal stack status
    local _portal_stack_status="ready"

    # Gateway status
    local _gateway_json_status="$GATEWAY_STATE"
    if [[ -z "$GATEWAY_ID" ]]; then
        _gateway_json_status="not_found"
    fi

    # Worker subnets status
    local _subnets_json_status="ready"

    # ReverseSlaveSG status
    local _sg_json_status="ready"
    if [[ -z "$REVERSE_SLAVE_SG" ]]; then
        _sg_json_status="missing"
    fi

    jq -n \
        --arg timestamp "$_timestamp" \
        --arg region "$REGION" \
        --arg portal_status "$_portal_stack_status" \
        --arg stack_name "${DISC[stack_name]:-}" \
        --arg vpc_id "${DISC[vpc_id]:-}" \
        --arg gateway_status "$_gateway_json_status" \
        --arg gateway_id "${GATEWAY_ID:-}" \
        --arg subnets_status "$_subnets_json_status" \
        --argjson subnet_ids "$_subnets_json" \
        --arg sg_status "$_sg_json_status" \
        --arg sg_id "${REVERSE_SLAVE_SG:-}" \
        --arg ami_status "$_ami_json_status" \
        --arg ami_id "$AMI_ID" \
        --arg ubl_endpoint_status "$_ubl_endpoint_json_status" \
        --arg ubl_endpoint_id "${UBL_ENDPOINT_ID:-}" \
        --arg ubl_secret_status "$_ubl_secret_json_status" \
        --argjson ubl_secret_fresh "$_ubl_secret_fresh" \
        --argjson ready "$OVERALL_READY" \
        --arg next_action "$NEXT_ACTION" \
        '{
            timestamp: $timestamp,
            region: $region,
            prerequisites: {
                portal_stack: {
                    status: $portal_status,
                    stack_name: $stack_name,
                    vpc_id: $vpc_id
                },
                gateway: {
                    status: $gateway_status,
                    instance_id: $gateway_id
                },
                worker_subnets: {
                    status: $subnets_status,
                    ids: $subnet_ids
                },
                reverse_slave_sg: {
                    status: $sg_status,
                    id: $sg_id
                },
                ami: {
                    status: $ami_status,
                    ami_id: $ami_id
                },
                ubl_endpoint: {
                    status: $ubl_endpoint_status,
                    endpoint_id: $ubl_endpoint_id
                },
                ubl_secret: {
                    status: $ubl_secret_status,
                    fresh: $ubl_secret_fresh
                }
            },
            ready: $ready,
            next_action: $next_action
        }'
}

# ── JSON error output (for hard failures) ─────────────────────────────────────
_output_json_error() {
    local error_code="$1"
    local next_action="$2"
    local _timestamp
    _timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    jq -n \
        --arg timestamp "$_timestamp" \
        --arg region "$REGION" \
        --arg error "$error_code" \
        --argjson ready "false" \
        --arg next_action "$next_action" \
        '{
            timestamp: $timestamp,
            region: $region,
            error: $error,
            ready: $ready,
            next_action: $next_action
        }'
}

# ── Human-readable output ─────────────────────────────────────────────────────
_output_human() {
    echo ""
    echo "=== Portal Region Readiness Checklist ==="
    echo ""

    printf "%-26s %s\n" "PREREQUISITE" "STATUS"
    printf "%-26s %s\n" "--------------------------" "----------------------------------------"

    # Portal Stack
    printf "%-26s ✅ %s\n" "Portal Stack" "CREATE_COMPLETE (${DISC[stack_name]:-})"

    # Gateway
    if [[ "$GATEWAY_STATE" == "running" ]]; then
        printf "%-26s ✅ %s\n" "Gateway" "running (${GATEWAY_ID:-})"
    elif [[ -n "$GATEWAY_ID" ]]; then
        printf "%-26s ⚠️  %s\n" "Gateway" "${GATEWAY_STATE} (savings mode)"
    else
        printf "%-26s ⚠️  %s\n" "Gateway" "not found"
    fi

    # Worker Subnets
    if (( SUBNET_COUNT > 0 )); then
        printf "%-26s ✅ %d found (%s)\n" "Worker Subnets" "$SUBNET_COUNT" "$WORKER_SUBNETS"
    else
        printf "%-26s ❌ %s\n" "Worker Subnets" "none found"
    fi

    # ReverseSlaveSG
    if [[ -n "$REVERSE_SLAVE_SG" ]]; then
        printf "%-26s ✅ %s\n" "ReverseSlaveSG" "$REVERSE_SLAVE_SG"
    else
        printf "%-26s ❌ %s\n" "ReverseSlaveSG" "not found"
    fi

    # AMI in Region
    case "$AMI_STATUS" in
        exists|copied_ok)
            printf "%-26s ✅ %s\n" "AMI in Region" "$AMI_ID"
            ;;
        needs_copy_from:*)
            printf "%-26s ⚠️  %s\n" "AMI in Region" "needs copy from ${SOURCE_REGION}"
            ;;
        copying)
            printf "%-26s ⏳ %s\n" "AMI in Region" "copy in progress"
            ;;
        copy_failed)
            printf "%-26s ❌ %s\n" "AMI in Region" "copy failed"
            ;;
        *)
            printf "%-26s ❓ %s\n" "AMI in Region" "$AMI_STATUS"
            ;;
    esac

    # UBL Endpoint
    case "$UBL_ENDPOINT_STATUS" in
        ready)
            printf "%-26s ✅ %s (%s)\n" "UBL Endpoint" "ready" "${UBL_ENDPOINT_ID}"
            ;;
        not_found)
            printf "%-26s ⚠️  %s\n" "UBL Endpoint" "not found"
            ;;
        stopped)
            printf "%-26s ⚠️  %s (%s)\n" "UBL Endpoint" "stopped" "${UBL_ENDPOINT_ID}"
            ;;
        *)
            printf "%-26s ❓ %s\n" "UBL Endpoint" "$UBL_ENDPOINT_STATUS"
            ;;
    esac

    # UBL Secret
    case "$UBL_SECRET_MATCH" in
        match)
            if [[ "$UBL_SECRET_FRESH" == "fresh" ]]; then
                printf "%-26s ✅ %s\n" "UBL Secret" "match, fresh"
            else
                printf "%-26s ✅ %s\n" "UBL Secret" "match, stale"
            fi
            ;;
        mismatch)
            printf "%-26s ⚠️  %s\n" "UBL Secret" "stale (mismatch)"
            ;;
        no_secret|missing)
            printf "%-26s ⚠️  %s\n" "UBL Secret" "missing"
            ;;
        no_endpoint)
            printf "%-26s ⚠️  %s\n" "UBL Secret" "no endpoint to compare"
            ;;
        *)
            printf "%-26s ❓ %s\n" "UBL Secret" "$UBL_SECRET_MATCH"
            ;;
    esac

    echo ""
    echo "=== Next Action ==="
    echo "  $NEXT_ACTION"
    echo ""
}

# ── GitLab workflow update ────────────────────────────────────────────────────
_update_workflow_issue() {
    echo "Updating workflow issue #${WORKFLOW_ISSUE}..." >&2

    # 1. Build JSON output for state_write
    local _json_output
    _json_output=$(jq -n \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg region "$REGION" \
        --arg stack_name "${DISC[stack_name]:-}" \
        --arg vpc_id "${DISC[vpc_id]:-}" \
        --arg gateway_id "${GATEWAY_ID:-}" \
        --arg gateway_state "$GATEWAY_STATE" \
        --arg ami_id "$AMI_ID" \
        --arg ami_status "$AMI_STATUS" \
        --arg ubl_endpoint_id "${UBL_ENDPOINT_ID:-}" \
        --arg ubl_endpoint_status "$UBL_ENDPOINT_STATUS" \
        --arg next_action "$NEXT_ACTION" \
        '{
            prepare_portal_region: {
                timestamp: $timestamp,
                region: $region,
                stack_name: $stack_name,
                vpc_id: $vpc_id,
                gateway_id: $gateway_id,
                gateway_state: $gateway_state,
                ami_id: $ami_id,
                ami_status: $ami_status,
                ubl_endpoint_id: $ubl_endpoint_id,
                ubl_endpoint_status: $ubl_endpoint_status,
                next_action: $next_action
            }
        }')

    # 2. state_write
    state_write "$WORKFLOW_ISSUE" "$_json_output" || {
        echo "WARNING: state_write failed for issue #${WORKFLOW_ISSUE}" >&2
    }

    # 3. Build inventory markdown
    local _ami_inventory_status
    case "$AMI_STATUS" in
        exists|copied_ok) _ami_inventory_status="exists" ;;
        *) _ami_inventory_status="needs_copy" ;;
    esac

    local _gateway_inventory_state="${GATEWAY_STATE:-not_found}"
    local _ubl_endpoint_inventory_status
    if [[ "$UBL_ENDPOINT_STATUS" == "ready" ]]; then
        _ubl_endpoint_inventory_status="ready"
    else
        _ubl_endpoint_inventory_status="not_found"
    fi

    local _ubl_secret_inventory_status
    case "$UBL_SECRET_MATCH" in
        match) _ubl_secret_inventory_status="match" ;;
        mismatch) _ubl_secret_inventory_status="stale" ;;
        *) _ubl_secret_inventory_status="missing" ;;
    esac

    local _inventory_md
    _inventory_md="## Resource Inventory
- **Portal Stack:** ${DISC[stack_name]:-unknown} (CREATE_COMPLETE)
- **VPC:** ${DISC[vpc_id]:-unknown}
- **Gateway:** ${GATEWAY_ID:-none} (${_gateway_inventory_state})
- **Worker Subnets:** ${WORKER_SUBNETS:-none}
- **ReverseSlaveSG:** ${REVERSE_SLAVE_SG:-none}
- **AMI:** ${AMI_ID} (${_ami_inventory_status})
- **UBL Endpoint:** ${UBL_ENDPOINT_ID:-none} (${_ubl_endpoint_inventory_status})
- **UBL Secret:** houdini/license-endpoint-dns (${_ubl_secret_inventory_status})"

    issue_update_inventory "$WORKFLOW_ISSUE" "$_inventory_md" || {
        echo "WARNING: issue_update_inventory failed for issue #${WORKFLOW_ISSUE}" >&2
    }

    # 4. issue_update_next_action
    issue_update_next_action "$WORKFLOW_ISSUE" "$NEXT_ACTION" || {
        echo "WARNING: issue_update_next_action failed for issue #${WORKFLOW_ISSUE}" >&2
    }

    # 5. issue_log
    issue_log "$WORKFLOW_ISSUE" "Portal region preparation completed" || {
        echo "WARNING: issue_log failed for issue #${WORKFLOW_ISSUE}" >&2
    }

    echo "Workflow issue #${WORKFLOW_ISSUE} updated." >&2
}

# ── Entry point ───────────────────────────────────────────────────────────────
main "$@"

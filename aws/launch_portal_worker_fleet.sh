#!/usr/bin/env bash
# aws/launch_portal_worker_fleet.sh — EC2 Spot/On-Demand Fleet launcher for Portal workers
# Purpose: Build and validate the EC2 Fleet launch specification using Portal resources,
#          then submit with --yes protection.
# Preconditions: aws CLI, jq installed; valid AWS credentials configured;
#                Portal stack deployed and UBL endpoint ready.

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
# shellcheck source=lib/fleet_resources.sh
source "${SCRIPT_DIR}/lib/fleet_resources.sh"
# shellcheck source=lib/ubl_check.sh
source "${SCRIPT_DIR}/lib/ubl_check.sh"
# shellcheck source=lib/portal_discovery.sh
source "${SCRIPT_DIR}/lib/portal_discovery.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
DEFAULT_TARGET_CAPACITY=1
DEFAULT_INSTANCE_TYPES="g6.2xlarge,g6.4xlarge,g6.8xlarge,g6.16xlarge"
DEFAULT_SOURCE_AMI="ami-0f70342f66dc80ddb"
DEFAULT_MODE="spot"

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
    # ── Step 1: CLI parsing ───────────────────────────────────────────────────
    local REGION=""
    local TARGET_CAPACITY=""
    local INSTANCE_TYPES_CSV=""
    local SOURCE_AMI=""
    local STACK_NAME=""
    local MODE=""
    local DRY_RUN=0
    local AUTO_YES=0
    local REPLACE=0
    local JSON_OUTPUT=0
    local WORKFLOW_ISSUE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --region)
                REGION="$2"
                shift 2
                ;;
            --target-capacity)
                TARGET_CAPACITY="$2"
                shift 2
                ;;
            --instance-types)
                INSTANCE_TYPES_CSV="$2"
                shift 2
                ;;
            --source-ami)
                SOURCE_AMI="$2"
                shift 2
                ;;
            --stack-name)
                STACK_NAME="$2"
                shift 2
                ;;
            --spot)
                MODE="spot"
                shift
                ;;
            --on-demand)
                MODE="on-demand"
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --yes)
                AUTO_YES=1
                shift
                ;;
            --replace)
                REPLACE=1
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
    [[ -z "$TARGET_CAPACITY" ]] && TARGET_CAPACITY="$DEFAULT_TARGET_CAPACITY"
    [[ -z "$INSTANCE_TYPES_CSV" ]] && INSTANCE_TYPES_CSV="$DEFAULT_INSTANCE_TYPES"
    [[ -z "$SOURCE_AMI" ]] && SOURCE_AMI="$DEFAULT_SOURCE_AMI"
    [[ -z "$MODE" ]] && MODE="$DEFAULT_MODE"

    # Validate required args
    if [[ -z "$REGION" ]]; then
        echo "ERROR: --region is required" >&2
        exit 1
    fi

    # Expand instance types from comma list
    local -a INSTANCE_TYPES=()
    IFS=',' read -ra INSTANCE_TYPES <<< "$INSTANCE_TYPES_CSV"

    if (( ${#INSTANCE_TYPES[@]} == 0 )); then
        echo "ERROR: no instance types specified" >&2
        exit 1
    fi

    # ── Dry-run: print expanded args and exit ─────────────────────────────────
    if (( DRY_RUN )) && ! (( AUTO_YES )); then
        echo "Region:           $REGION"
        echo "Mode:             $MODE"
        echo "Target Capacity:  $TARGET_CAPACITY"
        echo "Instance Types:   ${INSTANCE_TYPES[*]}"
        echo "Source AMI:       $SOURCE_AMI"
        echo "Stack Name:       ${STACK_NAME:-auto-discover}"
        echo "Replace:          $REPLACE"
        echo "JSON output:      $JSON_OUTPUT"
        echo "Workflow issue:   ${WORKFLOW_ISSUE:-none}"
        exit 0
    fi

    # ── Dependency check (after basic dry-run so it works without deps) ───────
    _check_deps

    # ── Step 2: Discover Portal resources ─────────────────────────────────────
    echo "Discovering Portal resources in $REGION..." >&2

    local RESOURCES_FILE
    RESOURCES_FILE=$(_make_temp)

    local fleet_args=(--region "$REGION")
    [[ -n "$STACK_NAME" ]] && fleet_args+=(--stack-name "$STACK_NAME")

    if ! query_fleet_resources "${fleet_args[@]}" > "$RESOURCES_FILE"; then
        echo "ERROR: Failed to query fleet resources in $REGION" >&2
        if (( JSON_OUTPUT )); then
            _output_json_error "fleet_resources_failed" \
                "query_fleet_resources failed — check Portal stack in $REGION"
        fi
        exit 1
    fi

    # Parse JSON output into variables
    local FR_STACK_NAME FR_STACK_STATUS FR_VPC_ID
    local FR_REVERSE_SLAVE_SG FR_WORKER_PROFILE_ARN FR_FLEET_ROLE_ARN
    local FR_PORTAL_BUCKET FR_GATEWAY_CERT

    FR_STACK_NAME=$(jq -r '.stack_name // empty' "$RESOURCES_FILE")
    FR_STACK_STATUS=$(jq -r '.stack_status // empty' "$RESOURCES_FILE")
    FR_VPC_ID=$(jq -r '.vpc_id // empty' "$RESOURCES_FILE")
    FR_REVERSE_SLAVE_SG=$(jq -r '.reverse_slave_sg_id // empty' "$RESOURCES_FILE")
    FR_WORKER_PROFILE_ARN=$(jq -r '.iam.worker_instance_profile_arn // empty' "$RESOURCES_FILE")
    FR_FLEET_ROLE_ARN=$(jq -r '.iam.fleet_role_arn // empty' "$RESOURCES_FILE")
    # shellcheck disable=SC2034
    FR_PORTAL_BUCKET=$(jq -r '.portal_client_bucket // empty' "$RESOURCES_FILE")
    # shellcheck disable=SC2034
    FR_GATEWAY_CERT=$(jq -r '.gateway_cert_path // empty' "$RESOURCES_FILE")

    # Extract worker subnets as bash array
    local -a WORKER_SUBNETS=()
    local _subnet
    while IFS= read -r _subnet; do
        [[ -n "$_subnet" ]] && WORKER_SUBNETS+=("$_subnet")
    done < <(jq -r '.worker_subnets[] // empty' "$RESOURCES_FILE")

    # Extract stack tags as JSON string
    local STACK_TAGS_JSON
    STACK_TAGS_JSON=$(jq -c '.stack_tags // {}' "$RESOURCES_FILE")

    # Validate required resources
    if [[ "$FR_STACK_STATUS" != "CREATE_COMPLETE" ]]; then
        echo "ERROR: Portal stack '${FR_STACK_NAME:-unknown}' status is '${FR_STACK_STATUS:-unknown}', expected CREATE_COMPLETE" >&2
        if (( JSON_OUTPUT )); then
            _output_json_error "portal_stack_invalid" \
                "Portal stack not CREATE_COMPLETE — deploy Portal first"
        fi
        exit 1
    fi

    if (( ${#WORKER_SUBNETS[@]} == 0 )); then
        echo "ERROR: No worker subnets found in Portal stack" >&2
        if (( JSON_OUTPUT )); then
            _output_json_error "subnets_missing" \
                "Portal stack incomplete — no worker subnets"
        fi
        exit 1
    fi

    if [[ -z "$FR_REVERSE_SLAVE_SG" ]]; then
        echo "ERROR: ReverseSlaveSG not found in Portal stack" >&2
        if (( JSON_OUTPUT )); then
            _output_json_error "sg_missing" \
                "Portal stack incomplete — no ReverseSlaveSG"
        fi
        exit 1
    fi

    if [[ -z "$FR_WORKER_PROFILE_ARN" ]]; then
        echo "ERROR: IAM worker instance profile ARN not found (AWSPortalWorkerRole)" >&2
        if (( JSON_OUTPUT )); then
            _output_json_error "iam_missing" \
                "AWSPortalWorkerRole instance profile missing"
        fi
        exit 1
    fi

    if [[ "$MODE" == "spot" ]] && [[ -z "$FR_FLEET_ROLE_ARN" ]]; then
        echo "ERROR: IAM fleet role ARN not found (DeadlineSpotFleetRole)" >&2
        if (( JSON_OUTPUT )); then
            _output_json_error "iam_missing" \
                "DeadlineSpotFleetRole fleet role missing"
        fi
        exit 1
    fi

    echo "  Stack:            ${FR_STACK_NAME} (CREATE_COMPLETE)" >&2
    echo "  VPC:              ${FR_VPC_ID:-not found}" >&2
    echo "  Worker subnets:   ${#WORKER_SUBNETS[@]} (${WORKER_SUBNETS[*]})" >&2
    echo "  ReverseSlaveSG:   ${FR_REVERSE_SLAVE_SG}" >&2
    echo "  Worker IAM:       ${FR_WORKER_PROFILE_ARN}" >&2
    [[ -n "$FR_FLEET_ROLE_ARN" ]] && echo "  Fleet IAM:        ${FR_FLEET_ROLE_ARN}" >&2

    # ── Step 3: Validate UBL endpoint ─────────────────────────────────────────
    echo "Validating UBL endpoint..." >&2

    local UBL_FILE
    UBL_FILE=$(_make_temp)

    local ubl_args=(--region "$REGION")
    if [[ -n "$FR_VPC_ID" ]]; then
        ubl_args+=(--vpc-id "$FR_VPC_ID")
    fi

    if ! query_ubl_check "${ubl_args[@]}" > "$UBL_FILE" 2>/dev/null; then
        echo "WARNING: UBL check encountered errors" >&2
    fi

    # Parse UBL check TSV output
    # Columns: REGION  CHECK_NAME  VALUE  STATUS  RESOURCE_KEY
    local UBL_ENDPOINT_STATUS="not_found"
    local _u_region _u_check _u_value _u_status _u_key
    while IFS=$'\t' read -r _u_region _u_check _u_value _u_status _u_key; do
        [[ "$_u_region" == "REGION" ]] && continue
        case "$_u_check" in
            ubl_endpoint)
                UBL_ENDPOINT_STATUS="$_u_status"
                ;;
        esac
    done < "$UBL_FILE"

    if [[ "$UBL_ENDPOINT_STATUS" == "not_found" ]]; then
        echo "ERROR: Refusing: UBL endpoint missing or wrong VPC" >&2
        if [[ -n "$WORKFLOW_ISSUE" ]]; then
            issue_update_next_action "$WORKFLOW_ISSUE" \
                "Set up UBL endpoint in $REGION before launching workers" || true
            issue_log "$WORKFLOW_ISSUE" "Fleet launch refused: UBL endpoint missing" || true
        fi
        if (( JSON_OUTPUT )); then
            _output_json_error "ubl_missing" \
                "UBL endpoint missing or wrong VPC — cannot launch workers"
        fi
        exit 1
    fi

    echo "  UBL endpoint:     ${UBL_ENDPOINT_STATUS}" >&2

    # ── Step 4: Validate Portal stack (explicit) ──────────────────────────────
    # Already validated in step 2 — stack_status == CREATE_COMPLETE
    echo "  Portal stack:     CREATE_COMPLETE ✓" >&2

    # ── Step 5: Build launch template overrides ───────────────────────────────
    echo "Building launch template overrides..." >&2

    # Build overrides array: instance_type × subnet
    local -a OVERRIDE_TYPES=()
    local -a OVERRIDE_SUBNETS=()
    local _itype _subnet
    for _itype in "${INSTANCE_TYPES[@]}"; do
        for _subnet in "${WORKER_SUBNETS[@]}"; do
            OVERRIDE_TYPES+=("$_itype")
            OVERRIDE_SUBNETS+=("$_subnet")
        done
    done

    local OVERRIDE_COUNT=${#OVERRIDE_TYPES[@]}
    echo "  Overrides:        ${OVERRIDE_COUNT} (${#INSTANCE_TYPES[@]} types × ${#WORKER_SUBNETS[@]} subnets)" >&2

    # Build the launch template data JSON
    # TagSpecifications from stack tags
    local TAG_SPECS_JSON="[]"
    if [[ "$STACK_TAGS_JSON" != "{}" ]]; then
        TAG_SPECS_JSON=$(jq -n \
            --argjson tags "$STACK_TAGS_JSON" \
            '[{
                ResourceType: "instance",
                Tags: ($tags | to_entries | map({Key: .key, Value: .value}))
            }, {
                ResourceType: "volume",
                Tags: ($tags | to_entries | map({Key: .key, Value: .value}))
            }]')
    else
        TAG_SPECS_JSON=$(jq -n '[{
            ResourceType: "instance",
            Tags: [{Key: "Name", Value: "portal-worker"}]
        }, {
            ResourceType: "volume",
            Tags: [{Key: "Name", Value: "portal-worker"}]
        }]')
    fi

    # Build overrides JSON for the fleet API
    local OVERRIDES_JSON="[]"
    local _idx
    for _idx in "${!OVERRIDE_TYPES[@]}"; do
        OVERRIDES_JSON=$(echo "$OVERRIDES_JSON" | jq \
            --arg itype "${OVERRIDE_TYPES[$_idx]}" \
            --arg subnet "${OVERRIDE_SUBNETS[$_idx]}" \
            --arg ami "$SOURCE_AMI" \
            '. + [{
                InstanceType: $itype,
                SubnetId: $subnet,
                ImageId: $ami
            }]')
    done

    # ── Step 6: Print full launch plan ────────────────────────────────────────
    local SUBNETS_STR
    SUBNETS_STR=$(IFS=','; echo "${WORKER_SUBNETS[*]}")

    local FLEET_ROLE_DISPLAY="${FR_FLEET_ROLE_ARN##*/}"
    local WORKER_ROLE_DISPLAY="${FR_WORKER_PROFILE_ARN##*/}"

    echo "" >&2
    echo "=== Launch Plan ===" >&2
    echo "Region:           $REGION" >&2
    echo "Mode:             $MODE" >&2
    echo "Target Capacity:  $TARGET_CAPACITY" >&2
    echo "Instance Types:   ${INSTANCE_TYPES[*]}" >&2
    echo "Subnets:          $SUBNETS_STR" >&2
    echo "Security Group:   $FR_REVERSE_SLAVE_SG" >&2
    echo "AMI:              $SOURCE_AMI" >&2
    echo "IAM Profile:      $WORKER_ROLE_DISPLAY" >&2
    echo "Fleet Role:       ${FLEET_ROLE_DISPLAY:-N/A (on-demand)}" >&2
    echo "Estimated cost:   N/A — use scan_gpu_capacity for pricing" >&2
    echo "" >&2
    echo "Overrides:" >&2
    for _idx in "${!OVERRIDE_TYPES[@]}"; do
        echo "  ${OVERRIDE_TYPES[$_idx]} × ${OVERRIDE_SUBNETS[$_idx]}" >&2
    done
    echo "" >&2

    # ── Step 7: Dry-run validation ────────────────────────────────────────────
    if ! (( AUTO_YES )); then
        echo "Running dry-run validation with one override..." >&2
        local _first_type="${OVERRIDE_TYPES[0]}"
        local _first_subnet="${OVERRIDE_SUBNETS[0]}"

        local dry_run_output
        dry_run_output=$(aws ec2 run-instances \
            --region "$REGION" \
            --image-id "$SOURCE_AMI" \
            --instance-type "$_first_type" \
            --subnet-id "$_first_subnet" \
            --security-group-ids "$FR_REVERSE_SLAVE_SG" \
            --iam-instance-profile "Arn=$FR_WORKER_PROFILE_ARN" \
            --dry-run \
            2>&1 || true)

        if echo "$dry_run_output" | grep -q "DryRunOperation"; then
            echo "Dry-run validation passed" >&2
        elif echo "$dry_run_output" | grep -q "UnauthorizedOperation"; then
            echo "ERROR: Dry-run failed — unauthorized. Check IAM permissions." >&2
            if (( JSON_OUTPUT )); then
                _output_json_error "unauthorized" "Dry-run failed: unauthorized operation"
            fi
            exit 1
        else
            echo "WARNING: Dry-run returned unexpected result:" >&2
            echo "  $dry_run_output" >&2
            # Continue anyway — some errors are expected in dry-run
        fi

        if (( JSON_OUTPUT )); then
            _output_json_plan
        fi

        echo "" >&2
        echo "Launch plan ready. Use --yes to submit the fleet request." >&2
        exit 0
    fi

    # ── Step 8: Submit fleet (with --yes) ─────────────────────────────────────

    # --replace: cancel existing fleet before launching new one
    if (( REPLACE )); then
        echo "Checking for existing fleet to replace..." >&2
        # Look for existing fleet requests from this Portal stack
        local existing_fleets
        existing_fleets=$(aws ec2 describe-fleets \
            --region "$REGION" \
            --fleet-ids "$fleet_id" \
            --query 'Fleets[?FleetState==`active`].FleetId' \
            --output text 2>/dev/null || echo "")

        if [[ -n "$existing_fleets" && "$existing_fleets" != "None" ]]; then
            local _fleet_id
            for _fleet_id in $existing_fleets; do
                echo "  Cancelling existing fleet: $_fleet_id" >&2
                aws ec2 delete-fleets \
                    --region "$REGION" \
                    --fleet-ids "$_fleet_id" \
                    --output json >/dev/null 2>&1 || {
                    echo "WARNING: Failed to cancel fleet $_fleet_id" >&2
                }
            done
        else
            echo "  No active fleets found to replace." >&2
        fi
    fi

    local FLEET_REQUEST_ID=""

    if [[ "$MODE" == "spot" ]]; then
        echo "Submitting EC2 Spot Fleet request..." >&2
        FLEET_REQUEST_ID=$(_submit_ec2_fleet_spot) || {
            echo "ERROR: EC2 Fleet submission failed" >&2
            if (( JSON_OUTPUT )); then
                _output_json_error "fleet_submit_failed" "EC2 Fleet submission failed"
            fi
            exit 1
        }
    else
        echo "Submitting EC2 On-Demand Fleet request..." >&2
        FLEET_REQUEST_ID=$(_submit_ec2_fleet_ondemand) || {
            echo "ERROR: EC2 Fleet submission failed" >&2
            if (( JSON_OUTPUT )); then
                _output_json_error "fleet_submit_failed" "EC2 Fleet submission failed"
            fi
            exit 1
        }
    fi

    echo "  Fleet ID: $FLEET_REQUEST_ID" >&2

    # ── Step 9: Tag launched resources ────────────────────────────────────────
    echo "Tagging fleet resources..." >&2

    # Apply Portal stack tags to the fleet itself
    local _tag_args=()
    if [[ "$STACK_TAGS_JSON" != "{}" ]]; then
        while IFS='=' read -r _tkey _tval; do
            _tag_args+=("Key=${_tkey},Value=${_tval}")
        done < <(echo "$STACK_TAGS_JSON" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
    else
        _tag_args+=("Key=Name,Value=portal-worker-fleet")
    fi

    if [[ "$MODE" == "spot" ]] && [[ "$FLEET_REQUEST_ID" == sfr-* ]]; then
        # Tag Spot Fleet Request
        aws ec2 create-tags \
            --region "$REGION" \
            --resources "$FLEET_REQUEST_ID" \
            --tags "${_tag_args[@]}" 2>/dev/null || {
            echo "WARNING: Failed to tag fleet request $FLEET_REQUEST_ID" >&2
        }
    fi

    # Tag launched instances (best-effort: poll for instances)
    echo "  Waiting for instances to launch for tagging..." >&2
    local _tag_attempts=0
    local _tagged_instances=()
    while (( _tag_attempts < 12 )); do
        sleep 5
        local _instance_ids
        _instance_ids=$(aws ec2 describe-fleets \
            --region "$REGION" \
            --fleet-ids "$FLEET_REQUEST_ID" \
            --query 'Fleets[0].LaunchTemplateConfigs[0].Overrides[0].SubnetId' \
            --output text 2>/dev/null || true)

        # Try to get instances from the fleet
        local _fleet_instances
        _fleet_instances=$(aws ec2 describe-fleet-instances \
            --region "$REGION" \
            --fleet-id "$FLEET_REQUEST_ID" \
            --query 'Instances[].InstanceId' \
            --output text 2>/dev/null || true)

        if [[ -n "$_fleet_instances" && "$_fleet_instances" != "None" ]]; then
            local _iid
            for _iid in $_fleet_instances; do
                # Check if already tagged
                if [[ ! " ${_tagged_instances[*]} " =~ ${_iid} ]]; then
                    aws ec2 create-tags \
                        --region "$REGION" \
                        --resources "$_iid" \
                        --tags "${_tag_args[@]}" 2>/dev/null || true
                    _tagged_instances+=("$_iid")
                fi
            done
        fi

        (( _tag_attempts++ ))
    done

    if (( ${#_tagged_instances[@]} > 0 )); then
        echo "  Tagged ${#_tagged_instances[@]} instance(s)" >&2
    else
        echo "  No instances found yet for tagging (fleet still launching)" >&2
    fi

    # ── Output result ─────────────────────────────────────────────────────────
    if (( JSON_OUTPUT )); then
        _output_json_result "$FLEET_REQUEST_ID"
    else
        _output_human_result "$FLEET_REQUEST_ID"
    fi

    # ── Step 10: GitLab workflow ──────────────────────────────────────────────
    if [[ -n "$WORKFLOW_ISSUE" ]]; then
        _update_workflow_issue "$FLEET_REQUEST_ID"
    fi
}

# ── Submit EC2 Fleet (Spot) ──────────────────────────────────────────────────
_submit_ec2_fleet_spot() {
    # Build the spot options JSON
    local spot_options
    # shellcheck disable=SC2034
    spot_options=$(jq -n '{
        MaxTotalPrice: null,
        SpotAllocationStrategy: "capacity-optimized",
        MaintenanceStrategies: {
            ReplaceUnhealthyInstances: {}
        }
    }')

    # Build launch template configs JSON
    local lt_configs
    # shellcheck disable=SC2034
    lt_configs=$(jq -n \
        --argjson overrides "$OVERRIDES_JSON" \
        --arg sg "$FR_REVERSE_SLAVE_SG" \
        --arg profile_arn "$FR_WORKER_PROFILE_ARN" \
        --argjson tag_specs "$TAG_SPECS_JSON" \
        '{
            LaunchTemplateSpecification: {
                LaunchTemplateName: ("portal-worker-fleet-" + (now | tostring)),
                Version: "$Default"
            },
            Overrides: $overrides
        } | .LaunchTemplateSpecification.LaunchTemplateName as $ltname |
        {
            LaunchTemplateConfigs: [{
                LaunchTemplateSpecification: {
                    LaunchTemplateName: $ltname,
                    Version: "$Latest"
                },
                Overrides: $overrides
            }],
            SpotOptions: {
                MaxTotalPrice: null,
                SpotAllocationStrategy: "capacity-optimized",
                ReplaceUnhealthyInstances: true
            },
            TargetCapacitySpecification: {
                TotalTargetCapacity: 1,
                DefaultTargetCapacityType: "spot"
            },
            TagSpecifications: $tag_specs
        }')

    # First, create a launch template
    local lt_name
    lt_name="portal-worker-fleet-$(date +%s)"

    # Build user data (minimal bootstrap if not available)
    local USER_DATA_B64
    USER_DATA_B64=$(echo '#!/bin/bash
echo "Portal worker bootstrapping..."
# Worker will register with Portal via Portal client
' | base64 -w 0)

    local lt_result
    lt_result=$(aws ec2 create-launch-template \
        --region "$REGION" \
        --launch-template-name "$lt_name" \
        --version-description "Portal worker fleet launch template" \
        --launch-template-data "$(jq -n \
            --arg ami "$SOURCE_AMI" \
            --arg sg "$FR_REVERSE_SLAVE_SG" \
            --arg profile_arn "$FR_WORKER_PROFILE_ARN" \
            --arg ud "$USER_DATA_B64" \
            '{
                ImageId: $ami,
                SecurityGroupIds: [$sg],
                IamInstanceProfile: {Arn: $profile_arn},
                UserData: $ud,
                Monitoring: {Enabled: true}
            }')" \
        --tag-specifications "ResourceType=launch-template,Tags=[{Key=portal-fleet,Value=true}]" \
        --output json 2>&1) || {
        echo "ERROR: Failed to create launch template" >&2
        echo "$lt_result" >&2
        return 1
    }

    # Build override entries referencing the launch template
    local fleet_overrides="[]"
    for _idx in "${!OVERRIDE_TYPES[@]}"; do
        fleet_overrides=$(echo "$fleet_overrides" | jq \
            --arg itype "${OVERRIDE_TYPES[$_idx]}" \
            --arg subnet "${OVERRIDE_SUBNETS[$_idx]}" \
            '. + [{
                InstanceType: $itype,
                SubnetId: $subnet
            }]')
    done

    local target_cap="$TARGET_CAPACITY"

    # Submit the fleet
    local fleet_result
    fleet_result=$(aws ec2 create-fleet \
        --region "$REGION" \
        --launch-template-configs "$(jq -n \
            --arg lt_name "$lt_name" \
            --argjson overrides "$fleet_overrides" \
            '[{
                LaunchTemplateSpecification: {
                    LaunchTemplateName: $lt_name,
                    Version: "$Latest"
                },
                Overrides: $overrides
            }]')" \
        --target-capacity-specification "$(jq -n \
            --argjson total "$target_cap" \
            '{
                TotalTargetCapacity: $total,
                DefaultTargetCapacityType: "spot"
            }')" \
        --spot-options 'MaxTotalPrice=null,SpotAllocationStrategy=capacity-optimized,ReplaceUnhealthyInstances=true' \
        --output json 2>&1) || {
        echo "ERROR: create-fleet call failed" >&2
        echo "$fleet_result" >&2
        return 1
    }

    # Extract fleet ID
    local fleet_id
    fleet_id=$(echo "$fleet_result" | jq -r '.FleetId // empty')

    if [[ -z "$fleet_id" ]]; then
        echo "ERROR: No FleetId in response" >&2
        echo "$fleet_result" >&2
        return 1
    fi

    echo "$fleet_id"
}

# ── Submit EC2 Fleet (On-Demand) ─────────────────────────────────────────────
_submit_ec2_fleet_ondemand() {
    # Create launch template
    local lt_name
    lt_name="portal-worker-fleet-ondemand-$(date +%s)"

    local USER_DATA_B64
    USER_DATA_B64=$(echo '#!/bin/bash
echo "Portal worker bootstrapping..."
# Worker will register with Portal via Portal client
' | base64 -w 0)

    local lt_result
    lt_result=$(aws ec2 create-launch-template \
        --region "$REGION" \
        --launch-template-name "$lt_name" \
        --version-description "Portal worker on-demand fleet launch template" \
        --launch-template-data "$(jq -n \
            --arg ami "$SOURCE_AMI" \
            --arg sg "$FR_REVERSE_SLAVE_SG" \
            --arg profile_arn "$FR_WORKER_PROFILE_ARN" \
            --arg ud "$USER_DATA_B64" \
            '{
                ImageId: $ami,
                SecurityGroupIds: [$sg],
                IamInstanceProfile: {Arn: $profile_arn},
                UserData: $ud,
                Monitoring: {Enabled: true}
            }')" \
        --output json 2>&1) || {
        echo "ERROR: Failed to create launch template" >&2
        echo "$lt_result" >&2
        return 1
    }

    local fleet_overrides="[]"
    for _idx in "${!OVERRIDE_TYPES[@]}"; do
        fleet_overrides=$(echo "$fleet_overrides" | jq \
            --arg itype "${OVERRIDE_TYPES[$_idx]}" \
            --arg subnet "${OVERRIDE_SUBNETS[$_idx]}" \
            '. + [{
                InstanceType: $itype,
                SubnetId: $subnet
            }]')
    done

    local target_cap="$TARGET_CAPACITY"

    local fleet_result
    fleet_result=$(aws ec2 create-fleet \
        --region "$REGION" \
        --launch-template-configs "$(jq -n \
            --arg lt_name "$lt_name" \
            --argjson overrides "$fleet_overrides" \
            '[{
                LaunchTemplateSpecification: {
                    LaunchTemplateName: $lt_name,
                    Version: "$Latest"
                },
                Overrides: $overrides
            }]')" \
        --target-capacity-specification "$(jq -n \
            --argjson total "$target_cap" \
            '{
                TotalTargetCapacity: $total,
                DefaultTargetCapacityType: "on-demand"
            }')" \
        --on-demand-options 'AllocationStrategy=lowest-price' \
        --replace-unhealthy-instances \
        --output json 2>&1) || {
        echo "ERROR: create-fleet (on-demand) call failed" >&2
        echo "$fleet_result" >&2
        return 1
    }

    local fleet_id
    fleet_id=$(echo "$fleet_result" | jq -r '.FleetId // empty')

    if [[ -z "$fleet_id" ]]; then
        echo "ERROR: No FleetId in response" >&2
        echo "$fleet_result" >&2
        return 1
    fi

    echo "$fleet_id"
}

# ── JSON output: plan only (dry-run) ─────────────────────────────────────────
_output_json_plan() {
    local _timestamp
    _timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local _subnets_json
    _subnets_json=$(printf '%s\n' "${WORKER_SUBNETS[@]}" | jq -R . | jq -s .)

    local _types_json
    _types_json=$(printf '%s\n' "${INSTANCE_TYPES[@]}" | jq -R . | jq -s .)

    local _overrides_json
    _overrides_json="[]"
    local _idx
    for _idx in "${!OVERRIDE_TYPES[@]}"; do
        _overrides_json=$(echo "$_overrides_json" | jq \
            --arg itype "${OVERRIDE_TYPES[$_idx]}" \
            --arg subnet "${OVERRIDE_SUBNETS[$_idx]}" \
            --arg ami "$SOURCE_AMI" \
            '. + [{instance_type: $itype, subnet: $subnet, ami: $ami}]')
    done

    jq -n \
        --arg timestamp "$_timestamp" \
        --arg region "$REGION" \
        --arg mode "$MODE" \
        --argjson target_cap "$TARGET_CAPACITY" \
        --argjson types "$_types_json" \
        --argjson subnets "$_subnets_json" \
        --arg sg "$FR_REVERSE_SLAVE_SG" \
        --arg ami "$SOURCE_AMI" \
        --arg profile "$FR_WORKER_PROFILE_ARN" \
        --arg fleet_role "${FR_FLEET_ROLE_ARN:-null}" \
        --argjson overrides "$_overrides_json" \
        --argjson dry_run "true" \
        --argjson launched "false" \
        '{
            timestamp: $timestamp,
            region: $region,
            mode: $mode,
            target_capacity: $target_cap,
            instance_types: $types,
            subnets: $subnets,
            security_group: $sg,
            ami: $ami,
            iam_profile: $profile,
            fleet_role: $fleet_role,
            overrides: $overrides,
            dry_run: $dry_run,
            launched: $launched
        }'
}

# ── JSON output: launch result ───────────────────────────────────────────────
_output_json_result() {
    local fleet_id="$1"
    local _timestamp
    _timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local _subnets_json
    _subnets_json=$(printf '%s\n' "${WORKER_SUBNETS[@]}" | jq -R . | jq -s .)

    local _types_json
    _types_json=$(printf '%s\n' "${INSTANCE_TYPES[@]}" | jq -R . | jq -s .)

    local _overrides_json
    _overrides_json="[]"
    local _idx
    for _idx in "${!OVERRIDE_TYPES[@]}"; do
        _overrides_json=$(echo "$_overrides_json" | jq \
            --arg itype "${OVERRIDE_TYPES[$_idx]}" \
            --arg subnet "${OVERRIDE_SUBNETS[$_idx]}" \
            --arg ami "$SOURCE_AMI" \
            '. + [{instance_type: $itype, subnet: $subnet, ami: $ami}]')
    done

    jq -n \
        --arg timestamp "$_timestamp" \
        --arg region "$REGION" \
        --arg mode "$MODE" \
        --argjson target_cap "$TARGET_CAPACITY" \
        --argjson types "$_types_json" \
        --argjson subnets "$_subnets_json" \
        --arg sg "$FR_REVERSE_SLAVE_SG" \
        --arg ami "$SOURCE_AMI" \
        --arg profile "$FR_WORKER_PROFILE_ARN" \
        --arg fleet_role "${FR_FLEET_ROLE_ARN:-null}" \
        --argjson overrides "$_overrides_json" \
        --argjson dry_run "false" \
        --argjson launched "true" \
        --arg fleet_request_id "$fleet_id" \
        '{
            timestamp: $timestamp,
            region: $region,
            mode: $mode,
            target_capacity: $target_cap,
            instance_types: $types,
            subnets: $subnets,
            security_group: $sg,
            ami: $ami,
            iam_profile: $profile,
            fleet_role: $fleet_role,
            overrides: $overrides,
            dry_run: $dry_run,
            launched: $launched,
            fleet_request_id: $fleet_request_id
        }'
}

# ── JSON error output ────────────────────────────────────────────────────────
_output_json_error() {
    local error_code="$1"
    local next_action="$2"
    local _timestamp
    _timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    jq -n \
        --arg timestamp "$_timestamp" \
        --arg region "$REGION" \
        --arg error "$error_code" \
        --argjson launched "false" \
        --arg next_action "$next_action" \
        '{
            timestamp: $timestamp,
            region: $region,
            error: $error,
            launched: $launched,
            next_action: $next_action
        }'
}

# ── Human-readable result ────────────────────────────────────────────────────
_output_human_result() {
    local fleet_id="$1"
    echo ""
    echo "=== Fleet Launch Result ==="
    echo "  Fleet ID:         $fleet_id"
    echo "  Region:           $REGION"
    echo "  Mode:             $MODE"
    echo "  Target Capacity:  $TARGET_CAPACITY"
    echo "  Instance Types:   ${INSTANCE_TYPES[*]}"
    echo "  Subnets:          ${WORKER_SUBNETS[*]}"
    echo "  Security Group:   $FR_REVERSE_SLAVE_SG"
    echo "  AMI:              $SOURCE_AMI"
    echo ""
    echo "  Fleet submitted successfully."
    echo ""
    echo "=== Next Action ==="
    echo "  Run watch_worker_fleet --fleet-request-id $fleet_id --region $REGION"
    echo ""
}

# ── GitLab workflow update ───────────────────────────────────────────────────
_update_workflow_issue() {
    local fleet_id="$1"
    echo "Updating workflow issue #${WORKFLOW_ISSUE}..." >&2

    # 1. fsm_transition to FLEET_PLAN_READY
    fsm_transition "$WORKFLOW_ISSUE" "FLEET_PLAN_READY" || {
        echo "WARNING: fsm_transition to FLEET_PLAN_READY failed" >&2
    }

    # 2. If submitted (--yes), transition to FLEET_REQUESTED
    if (( AUTO_YES )); then
        fsm_transition "$WORKFLOW_ISSUE" "FLEET_REQUESTED" || {
            echo "WARNING: fsm_transition to FLEET_REQUESTED failed" >&2
        }
    fi

    # 3. state_write with fleet state JSON
    local _json_output
    _json_output=$(jq -n \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg region "$REGION" \
        --arg mode "$MODE" \
        --argjson target_cap "$TARGET_CAPACITY" \
        --arg fleet_id "$fleet_id" \
        --arg ami "$SOURCE_AMI" \
        --arg stack_name "${FR_STACK_NAME:-}" \
        --arg sg "$FR_REVERSE_SLAVE_SG" \
        '{
            launch_fleet: {
                timestamp: $timestamp,
                region: $region,
                mode: $mode,
                target_capacity: $target_cap,
                fleet_request_id: $fleet_id,
                ami: $ami,
                stack_name: $stack_name,
                security_group: $sg
            }
        }')

    state_write "$WORKFLOW_ISSUE" "$_json_output" || {
        echo "WARNING: state_write failed for issue #${WORKFLOW_ISSUE}" >&2
    }

    # 4. Build inventory markdown
    local _types_str
    _types_str=$(IFS=','; echo "${INSTANCE_TYPES[*]}")
    local _subnets_str
    _subnets_str=$(IFS=','; echo "${WORKER_SUBNETS[*]}")

    local _inventory_md
    _inventory_md="## Fleet Launch Inventory
- **Fleet ID:** ${fleet_id}
- **Region:** ${REGION}
- **Mode:** ${MODE}
- **Target Capacity:** ${TARGET_CAPACITY}
- **Instance Types:** ${_types_str}
- **Subnets:** ${_subnets_str}
- **Security Group:** ${FR_REVERSE_SLAVE_SG}
- **AMI:** ${SOURCE_AMI}
- **IAM Profile:** ${FR_WORKER_PROFILE_ARN##*/}
- **Fleet Role:** ${FR_FLEET_ROLE_ARN##*/}"

    issue_update_inventory "$WORKFLOW_ISSUE" "$_inventory_md" || {
        echo "WARNING: issue_update_inventory failed for issue #${WORKFLOW_ISSUE}" >&2
    }

    # 5. issue_update_next_action
    local _next_action="Fleet ${fleet_id} launched. Run watch_worker_fleet --fleet-request-id ${fleet_id}"
    issue_update_next_action "$WORKFLOW_ISSUE" "$_next_action" || {
        echo "WARNING: issue_update_next_action failed for issue #${WORKFLOW_ISSUE}" >&2
    }

    # 6. issue_log
    issue_log "$WORKFLOW_ISSUE" "Fleet launch submitted: ${fleet_id} (${MODE}, capacity=${TARGET_CAPACITY})" || {
        echo "WARNING: issue_log failed for issue #${WORKFLOW_ISSUE}" >&2
    }

    echo "Workflow issue #${WORKFLOW_ISSUE} updated." >&2
}

# ── Entry point ───────────────────────────────────────────────────────────────
main "$@"
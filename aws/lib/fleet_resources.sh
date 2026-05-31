#!/usr/bin/env bash
# aws/lib/fleet_resources.sh — Discover Portal resources for fleet launch
# Purpose: Discover all Portal-created IAM roles, security groups, subnets,
#          tags, user data etc. needed to construct a Spot/EC2 Fleet launch
#          request that reuses Portal infrastructure.
# Sourced by launch_portal_worker_fleet.sh; also runnable standalone.

set -euo pipefail

# ── AWS CLI path ──────────────────────────────────────────────────────────────
# uv-installed AWS CLI may not be on PATH; prefer it if found
AWS_CLI="/home/aoin/.cache/uv/archive-v0/FXuFsIxiijforE87cox8l/bin/aws"
if [[ -x "$AWS_CLI" ]]; then
    PATH="/home/aoin/.cache/uv/archive-v0/FXuFsIxiijforE87cox8l/bin:$PATH"
fi

# ── Resolve the directory this script lives in (for sourcing sibling libs) ───
_FR_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source portal_discovery.sh so we can call query_portal_discovery ──────────
# shellcheck source=aws/lib/portal_discovery.sh
source "${_FR_SELF_DIR}/portal_discovery.sh"

# ── Internal helpers ──────────────────────────────────────────────────────────

# Print an error message to stderr and return 1.
_fr_die() {
    echo "ERROR: $*" >&2
    return 1
}

# Execute an AWS CLI command (or dry-run print it to stderr).
# Usage: _fr_aws ARGS...
# Returns: JSON string on stdout when not in dry-run; nothing on stdout in dry-run.
_fr_aws() {
    if [[ "${_FR_DRY_RUN:-0}" == "1" ]]; then
        echo "aws $*" >&2
        return 0
    fi
    aws "$@"
}

# ── query_fleet_resources ────────────────────────────────────────────────────
# Args:
#   --region REGION       (required) AWS region
#   --stack-name NAME     (optional) specific stack name; auto-discover if omitted
#   --dry-run             (optional) print AWS CLI commands to stderr, exit 0
#   --header              (optional) not used (output is JSON)
#
# Output: JSON to stdout containing all discovered Portal resources for fleet
#         launch. Errors to stderr, exit non-zero on failure.
query_fleet_resources() {
    local region=""
    local stack_name=""
    local dry_run=0
    # --header accepted but unused (JSON output)

    # ── Parse arguments ───────────────────────────────────────────────────────
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --region)
                region="$2"
                shift 2
                ;;
            --stack-name)
                stack_name="$2"
                shift 2
                ;;
            --dry-run)
                dry_run=1
                shift
                ;;
            --header)
                # Accepted for CLI compatibility but not used (JSON output)
                shift
                ;;
            *)
                echo "ERROR: Unknown argument: $1" >&2
                return 1
                ;;
        esac
    done

    # ── Validate required arguments ───────────────────────────────────────────
    if [[ -z "$region" ]]; then
        echo "ERROR: --region is required" >&2
        return 1
    fi

    # Export for _fr_aws helper
    _FR_DRY_RUN="$dry_run"

    # ── Dry-run skeleton ──────────────────────────────────────────────────────
    if [[ "$dry_run" -eq 1 ]]; then
        # Print all the AWS CLI commands we *would* run
        echo "aws cloudformation describe-stacks --region $region --output json" >&2
        echo "aws cloudformation describe-stack-resources --region $region --stack-name <DISCOVERED_STACK> --output json" >&2
        echo "aws ec2 describe-instances --instance-ids <GATEWAY_ID> --region $region --output json" >&2
        echo "aws iam list-instance-profiles --region $region --output json" >&2
        echo "aws iam list-roles --region $region --output json" >&2
        echo "aws ec2 describe-instance-attribute --attribute userData --instance-id <INSTANCE_ID> --region $region --output json" >&2
        echo "aws ec2 describe-launch-templates --region $region --output json" >&2
        echo "aws cloudformation get-template --stack-name <DISCOVERED_STACK> --region $region --output json" >&2

        # Output skeleton JSON with null values
        jq -n \
            --arg region "$region" \
            '{
                region: $region,
                stack_name: null,
                stack_status: null,
                vpc_id: null,
                gateway: {
                    instance_id: null,
                    state: null
                },
                worker_subnets: [],
                reverse_slave_sg_id: null,
                iam: {
                    worker_instance_profile_arn: null,
                    fleet_role_arn: null
                },
                portal_client_bucket: null,
                gateway_cert_path: null,
                stack_tags: {},
                user_data_available: false,
                user_data_source: "none"
            }'
        return 0
    fi

    # ── Step 1: Call query_portal_discovery and capture TSV output ────────────
    local pd_args=(--region "$region")
    if [[ -n "$stack_name" ]]; then
        pd_args+=(--stack-name "$stack_name")
    fi

    local pd_output
    pd_output="$(query_portal_discovery "${pd_args[@]}")" || {
        echo "ERROR: Portal discovery failed for region $region" >&2
        return 1
    }

    # ── Parse the TSV output into associative array ───────────────────────────
    # Columns: REGION, STACK_NAME, STACK_STATUS, VALUE, RESOURCE_KEY
    declare -A pd_resources
    local discovered_stack_name=""
    local discovered_stack_status=""

    while IFS=$'\t' read -r _pd_region _pd_stack _pd_status _pd_value _pd_key; do
        # Skip header row if present
        [[ "$_pd_region" == "REGION" ]] && continue

        # Store stack-level info from first row
        if [[ -z "$discovered_stack_name" ]]; then
            discovered_stack_name="$_pd_stack"
            discovered_stack_status="$_pd_status"
        fi

        # Store value by resource key
        pd_resources["$_pd_key"]="$_pd_value"
    done <<< "$pd_output"

    if [[ -z "$discovered_stack_name" ]]; then
        echo "ERROR: No Portal stack discovered in $region" >&2
        return 1
    fi

    # ── Extract known resources from parsed TSV ───────────────────────────────
    local vpc_id="${pd_resources[vpc_id]:-}"
    local gateway_instance_id="${pd_resources[gateway_instance_id]:-}"
    local gateway_state="${pd_resources[gateway_state]:-unknown}"
    local worker_subnets_raw="${pd_resources[worker_subnet_ids]:-}"
    local reverse_slave_sg_id="${pd_resources[reverse_slave_sg_id]:-}"
    local portal_client_bucket="${pd_resources[portal_client_bucket]:-}"
    local gateway_cert_path="${pd_resources[gateway_cert_path]:-}"

    # ── Step 2: Discover IAM roles ────────────────────────────────────────────

    # Find AWSPortalWorkerRole instance profile
    local worker_instance_profile_arn="null"
    local ip_json
    ip_json="$(_fr_aws iam list-instance-profiles \
        --region "$region" \
        --output json)" || {
        echo "WARNING: Failed to list instance profiles in $region" >&2
    }

    if [[ -n "$ip_json" ]]; then
        worker_instance_profile_arn="$(echo "$ip_json" | jq -r '
            .InstanceProfiles[]
            | select(.InstanceProfileName | test("AWSPortalWorkerRole"; "i"))
            | .Arn
            | values
        ' | head -n 1)"

        if [[ -z "$worker_instance_profile_arn" ]]; then
            echo "WARNING: AWSPortalWorkerRole instance profile not found in $region" >&2
            worker_instance_profile_arn="null"
        fi
    fi

    # Find DeadlineSpotFleetRole (or AWSPortalFleetRole) fleet role
    local fleet_role_arn="null"
    local roles_json
    roles_json="$(_fr_aws iam list-roles \
        --region "$region" \
        --output json)" || {
        echo "WARNING: Failed to list roles in $region" >&2
    }

    if [[ -n "$roles_json" ]]; then
        fleet_role_arn="$(echo "$roles_json" | jq -r '
            .Roles[]
            | select(
                .RoleName | test("DeadlineSpotFleetRole|AWSPortalFleetRole"; "i")
            )
            | .Arn
            | values
        ' | head -n 1)"

        if [[ -z "$fleet_role_arn" ]]; then
            echo "WARNING: Fleet role (DeadlineSpotFleetRole / AWSPortalFleetRole) not found in $region" >&2
            fleet_role_arn="null"
        fi
    fi

    # ── Step 3: Discover Portal stack tags via CloudFormation ─────────────────
    local stack_tags_json="{}"
    local stack_detail_json
    stack_detail_json="$(_fr_aws cloudformation describe-stacks \
        --region "$region" \
        --stack-name "$discovered_stack_name" \
        --output json)" || {
        echo "WARNING: Failed to describe stack $discovered_stack_name for tags" >&2
    }

    if [[ -n "$stack_detail_json" ]]; then
        stack_tags_json="$(echo "$stack_detail_json" | jq '
            .Stacks[0].Tags // []
            | map({(.Key): .Value})
            | add // {}
        ')"
    fi

    # ── Step 4: Discover worker user data ─────────────────────────────────────
    local user_data_available=false
    local user_data_source="none"
    local user_data_value=""

    # Try strategy 1: Get user data from gateway instance attribute
    if [[ -n "$gateway_instance_id" && "$gateway_instance_id" != "" ]]; then
        local ud_json
        ud_json="$(_fr_aws ec2 describe-instance-attribute \
            --attribute userData \
            --instance-id "$gateway_instance_id" \
            --region "$region" \
            --output json)" 2>/dev/null || true

        if [[ -n "$ud_json" ]]; then
            user_data_value="$(echo "$ud_json" | jq -r '.UserData.Value // empty')"
            if [[ -n "$user_data_value" ]]; then
                user_data_available=true
                user_data_source="instance"
            fi
        fi
    fi

    # Try strategy 2: Look for Launch Template user data
    if [[ "$user_data_available" == "false" ]]; then
        local lt_json
        lt_json="$(_fr_aws ec2 describe-launch-templates \
            --region "$region" \
            --filters "Name=tag:aws:cloudformation:stack-name,Values=$discovered_stack_name" \
            --output json)" 2>/dev/null || true

        if [[ -n "$lt_json" ]]; then
            local lt_id
            lt_id="$(echo "$lt_json" | jq -r '.LaunchTemplates[0].LaunchTemplateId // empty')"
            if [[ -n "$lt_id" ]]; then
                local lt_version_json
                # shellcheck disable=SC2016
                lt_version_json="$(_fr_aws ec2 describe-launch-template-versions \
                    --launch-template-id "$lt_id" \
                    --versions '$Default' \
                    --region "$region" \
                    --output json)" 2>/dev/null || true

                if [[ -n "$lt_version_json" ]]; then
                    user_data_value="$(echo "$lt_version_json" | jq -r '
                        .LaunchTemplateVersions[0].LaunchTemplateData.UserData // empty
                    ')"
                    if [[ -n "$user_data_value" ]]; then
                        user_data_available=true
                        user_data_source="launch-template"
                    fi
                fi
            fi
        fi
    fi

    # Try strategy 3: Look in CloudFormation stack template for user data script
    if [[ "$user_data_available" == "false" ]]; then
        local cfn_template_json
        cfn_template_json="$(_fr_aws cloudformation get-template \
            --stack-name "$discovered_stack_name" \
            --region "$region" \
            --output json)" 2>/dev/null || true

        if [[ -n "$cfn_template_json" ]]; then
            # Look for UserData in the template (could be in various places)
            local has_user_data
            has_user_data="$(echo "$cfn_template_json" | jq '
                .. | objects | select(has("UserData")) | .UserData // empty
            ' 2>/dev/null | head -n 1)"

            if [[ -n "$has_user_data" ]]; then
                user_data_available=true
                user_data_source="stack-template"
            fi
        fi
    fi

    # ── Build worker_subnets JSON array ───────────────────────────────────────
    local worker_subnets_json="[]"
    if [[ -n "$worker_subnets_raw" ]]; then
        worker_subnets_json="$(echo "$worker_subnets_raw" | jq -R 'split(",")')"
    fi

    # ── Build gateway object ──────────────────────────────────────────────────
    local gateway_json
    gateway_json="$(jq -n \
        --arg iid "${gateway_instance_id:-null}" \
        --arg st "${gateway_state:-unknown}" \
        '{
            instance_id: (if $iid == "null" or $iid == "" then null else $iid end),
            state: (if $iid == "null" or $iid == "" then null else $st end)
        }')"

    # ── Build IAM object ──────────────────────────────────────────────────────
    local iam_json
    iam_json="$(jq -n \
        --arg wip "$worker_instance_profile_arn" \
        --arg fra "$fleet_role_arn" \
        '{
            worker_instance_profile_arn: (if $wip == "null" or $wip == "" then null else $wip end),
            fleet_role_arn: (if $fra == "null" or $fra == "" then null else $fra end)
        }')"

    # ── Build final JSON output ───────────────────────────────────────────────
    jq -n \
        --arg region "$region" \
        --arg stack_name "$discovered_stack_name" \
        --arg stack_status "$discovered_stack_status" \
        --arg vpc_id "${vpc_id:-null}" \
        --argjson gateway "$gateway_json" \
        --argjson worker_subnets "$worker_subnets_json" \
        --arg reverse_slave_sg_id "${reverse_slave_sg_id:-null}" \
        --argjson iam "$iam_json" \
        --arg portal_client_bucket "${portal_client_bucket:-null}" \
        --arg gateway_cert_path "${gateway_cert_path:-null}" \
        --argjson stack_tags "$stack_tags_json" \
        --argjson user_data_available "$user_data_available" \
        --arg user_data_source "$user_data_source" \
        '{
            region: $region,
            stack_name: $stack_name,
            stack_status: $stack_status,
            vpc_id: (if $vpc_id == "null" or $vpc_id == "" then null else $vpc_id end),
            gateway: $gateway,
            worker_subnets: $worker_subnets,
            reverse_slave_sg_id: (if $reverse_slave_sg_id == "null" or $reverse_slave_sg_id == "" then null else $reverse_slave_sg_id end),
            iam: $iam,
            portal_client_bucket: (if $portal_client_bucket == "null" or $portal_client_bucket == "" then null else $portal_client_bucket end),
            gateway_cert_path: (if $gateway_cert_path == "null" or $gateway_cert_path == "" then null else $gateway_cert_path end),
            stack_tags: $stack_tags,
            user_data_available: $user_data_available,
            user_data_source: $user_data_source
        }'
}

# ── Main guard: only run when executed directly ───────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    query_fleet_resources "$@"
fi

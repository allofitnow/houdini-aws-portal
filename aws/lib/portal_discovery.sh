#!/usr/bin/env bash
# aws/lib/portal_discovery.sh — Discover the active AWS Portal CloudFormation stack
# Purpose: Auto-discover or verify a Portal CFN stack and extract key resources.
# Sourced by prepare_portal_region, fleet_resources, etc.; also runnable standalone.

set -euo pipefail

# ── AWS CLI path ──────────────────────────────────────────────────────────────
# uv-installed AWS CLI may not be on PATH; prefer it if found
AWS_CLI="/home/aoin/.cache/uv/archive-v0/FXuFsIxiijforE87cox8l/bin/aws"
if [[ -x "$AWS_CLI" ]]; then
    PATH="/home/aoin/.cache/uv/archive-v0/FXuFsIxiijforE87cox8l/bin:$PATH"
fi

# ── Internal helpers ──────────────────────────────────────────────────────────

# Print an error message to stderr and return 1 / exit 1.
_pd_die() {
    echo "ERROR: $*" >&2
    return 1
}

# Execute an AWS CLI command (or dry-run print it to stderr).
# Usage: _pd_aws ARGS...
# Returns: JSON string on stdout when not in dry-run; nothing on stdout in dry-run.
_pd_aws() {
    if [[ "${_PD_DRY_RUN:-0}" == "1" ]]; then
        echo "aws $*" >&2
        return 0
    fi
    aws "$@"
}

# ── query_portal_discovery ────────────────────────────────────────────────────
# Args:
#   --region REGION       (required) single AWS region
#   --stack-name NAME     (optional) specific stack name; auto-discover if omitted
#   --dry-run             (optional) print AWS CLI commands to stderr, exit 0
#   --header              (optional) add TSV header row
#
# Output: TSV to stdout — REGION, STACK_NAME, STACK_STATUS, VALUE, RESOURCE_KEY
#         One line per discovered resource.
query_portal_discovery() {
    local region=""
    local stack_name=""
    local dry_run=0
    local header=0

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
                header=1
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

    # Export for _pd_aws helper
    _PD_DRY_RUN="$dry_run"

    # ── Optional header ───────────────────────────────────────────────────────
    if [[ "$header" -eq 1 ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "REGION" "STACK_NAME" "STACK_STATUS" "VALUE" "RESOURCE_KEY"
    fi

    # ── Auto-discovery or direct stack lookup ─────────────────────────────────
    local stack_json=""

    if [[ -n "$stack_name" ]]; then
        # ── Explicit stack name: describe that single stack ───────────────────
        stack_json="$(_pd_aws cloudformation describe-stacks \
            --region "$region" \
            --stack-name "$stack_name" \
            --output json)" || {
            echo "ERROR: Failed to describe stack '$stack_name' in $region" >&2
            return 1
        }
    else
        # ── Auto-discover: list all stacks and find the Portal stack ──────────
        stack_json="$(_pd_aws cloudformation describe-stacks \
            --region "$region" \
            --output json)" || {
            echo "ERROR: Failed to describe stacks in $region" >&2
            return 1
        }
    fi

    # In dry-run mode, _pd_aws printed commands to stderr and returned 0
    # with empty stdout — nothing more to do.
    if [[ "$dry_run" -eq 1 ]]; then
        # Print the remaining commands we would run
        echo "aws cloudformation describe-stack-resources --region $region --stack-name <DISCOVERED_STACK>" >&2
        echo "aws ec2 describe-instances --instance-ids <GATEWAY_ID> --region $region" >&2
        return 0
    fi

    # ── Extract the matching Portal stack ─────────────────────────────────────
    local stacks_json
    stacks_json="$(echo "$stack_json" | jq '.Stacks // []')"

    if [[ -n "$stack_name" ]]; then
        # With an explicit name, we already have exactly one stack
        local matched_count
        matched_count="$(echo "$stacks_json" | jq 'length')"
        if [[ "$matched_count" -eq 0 ]]; then
            echo "ERROR: Stack '$stack_name' not found in $region" >&2
            return 1
        fi
    else
        # Filter: name contains "AWSPortal" OR has tag DeadlineTrackedAWSResource
        local portal_stacks
        portal_stacks="$(echo "$stacks_json" | jq '
            map(select(
                (.StackName | test("AWSPortal"; "i"))
                or
                (.Tags // [] | map(.Key) | index("DeadlineTrackedAWSResource") != null)
            ))
        ')"

        local match_count
        match_count="$(echo "$portal_stacks" | jq 'length')"

        if [[ "$match_count" -eq 0 ]]; then
            echo "ERROR: No Portal CloudFormation stack found in $region" >&2
            return 1
        fi

        if [[ "$match_count" -gt 1 ]]; then
            local names
            names="$(echo "$portal_stacks" | jq -r '.[].StackName' | tr '\n' ' ')"
            echo "WARNING: Multiple Portal stacks found in $region: $names— using most recently created." >&2
        fi

        # Pick the most recently created stack (latest CreationTime)
        stacks_json="$(echo "$portal_stacks" | jq 'sort_by(.CreationTime) | reverse | .[0] | [.]')"
    fi

    # ── Extract stack-level fields ────────────────────────────────────────────
    local found_stack_name found_stack_status
    found_stack_name="$(echo "$stacks_json" | jq -r '.[0].StackName')"
    found_stack_status="$(echo "$stacks_json" | jq -r '.[0].StackStatus')"

    if [[ "$found_stack_status" != "CREATE_COMPLETE" ]]; then
        echo "ERROR: Stack '$found_stack_name' in $region has status '$found_stack_status'; expected CREATE_COMPLETE" >&2
        return 1
    fi

    # Capture the single stack object for later use
    local stack_obj
    stack_obj="$(echo "$stacks_json" | jq '.[0]')"

    # ── Describe stack resources ──────────────────────────────────────────────
    local resources_json
    resources_json="$(_pd_aws cloudformation describe-stack-resources \
        --region "$region" \
        --stack-name "$found_stack_name" \
        --output json)" || {
        echo "ERROR: Failed to describe stack resources for '$found_stack_name' in $region" >&2
        return 1
    }

    local resources_arr
    resources_arr="$(echo "$resources_json" | jq '.StackResources // []')"

    # ── Helper: emit one TSV row ──────────────────────────────────────────────
    _pd_row() {
        local value="$1"
        local resource_key="$2"
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$region" "$found_stack_name" "$found_stack_status" "$value" "$resource_key"
    }

    # ── Extract VPC ID ────────────────────────────────────────────────────────
    local vpc_id
    vpc_id="$(echo "$resources_arr" | jq -r '
        map(select(.ResourceType == "AWS::EC2::VPC"))[0].PhysicalResourceId // empty
    ')"
    if [[ -n "$vpc_id" ]]; then
        _pd_row "$vpc_id" "vpc_id"
    fi

    # ── Extract Gateway instance ID ───────────────────────────────────────────
    # Look for AWS::EC2::Instance with "gateway" in LogicalId (case-insensitive)
    local gateway_id
    gateway_id="$(echo "$resources_arr" | jq -r '
        map(select(
            .ResourceType == "AWS::EC2::Instance"
            and ((.LogicalResourceId // "" | test("gateway"; "i"))
                 or ((.Tags // []) | map(.Value // "" | test("gateway"; "i")) | any))
        ))[0].PhysicalResourceId // empty
    ')"

    if [[ -n "$gateway_id" ]]; then
        _pd_row "$gateway_id" "gateway_instance_id"

        # ── Get actual gateway running state ──────────────────────────────────
        local gw_state_json
        gw_state_json="$(_pd_aws ec2 describe-instances \
            --instance-ids "$gateway_id" \
            --region "$region" \
            --output json)" || {
            echo "WARNING: Failed to describe gateway instance $gateway_id" >&2
        }

        if [[ -n "$gw_state_json" ]]; then
            local gw_state
            gw_state="$(echo "$gw_state_json" | jq -r '.Reservations[0].Instances[0].State.Name // "unknown"')"
            _pd_row "$gw_state" "gateway_state"
        fi
    fi

    # ── Extract worker private subnet IDs ─────────────────────────────────────
    # Look for AWS::EC2::Subnet resources; private subnets typically don't have
    # "public" or "Public" in their logical ID.  Collect all private subnets.
    local worker_subnets
    worker_subnets="$(echo "$resources_arr" | jq -r '
        map(select(
            .ResourceType == "AWS::EC2::Subnet"
            and ((.LogicalResourceId // "") | test("public"; "i") | not)
        ))
        | map(.PhysicalResourceId)
        | join(",")
    ')"
    if [[ -n "$worker_subnets" ]]; then
        _pd_row "$worker_subnets" "worker_subnet_ids"
    fi

    # ── Extract ReverseSlaveSG security group ID ──────────────────────────────
    local reverse_slave_sg
    reverse_slave_sg="$(echo "$resources_arr" | jq -r '
        map(select(
            .ResourceType == "AWS::EC2::SecurityGroup"
            and ((.LogicalResourceId // "") | test("ReverseSlave"; "i"))
        ))[0].PhysicalResourceId // empty
    ')"
    if [[ -n "$reverse_slave_sg" ]]; then
        _pd_row "$reverse_slave_sg" "reverse_slave_sg_id"
    fi

    # ── Extract Portal client S3 bucket ───────────────────────────────────────
    local portal_bucket
    portal_bucket="$(echo "$resources_arr" | jq -r '
        map(select(.ResourceType == "AWS::S3::Bucket"))[0].PhysicalResourceId // empty
    ')"
    if [[ -n "$portal_bucket" ]]; then
        _pd_row "$portal_bucket" "portal_client_bucket"
    fi

    # ── Extract gateway certificate path ──────────────────────────────────────
    # Check stack Outputs for cert-related values, then fall back to Parameters.
    local gateway_cert_path
    gateway_cert_path="$(echo "$stack_obj" | jq -r '
        (.Outputs // []) | map(select(
            (.OutputKey // "") | test("cert|Certificate|ssl|SSL"; "i")
        ))[0].OutputValue // empty
    ')"

    if [[ -z "$gateway_cert_path" ]]; then
        gateway_cert_path="$(echo "$stack_obj" | jq -r '
            (.Parameters // []) | map(select(
                (.ParameterKey // "") | test("cert|Certificate|ssl|SSL"; "i")
            ))[0].ParameterValue // empty
        ')"
    fi

    if [[ -n "$gateway_cert_path" ]]; then
        _pd_row "$gateway_cert_path" "gateway_cert_path"
    fi

    # ── Extract all DeadlineTrackedAWSResource tag values ──────────────────────
    local tracked_values
    tracked_values="$(echo "$stack_obj" | jq -r '
        (.Tags // []) | map(select(.Key == "DeadlineTrackedAWSResource")) | map(.Value) | join(",")
    ')"
    if [[ -n "$tracked_values" ]]; then
        _pd_row "$tracked_values" "deadline_tracked_aws_resource"
    fi
}

# ── Main guard: only run when executed directly ───────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    query_portal_discovery "$@"
fi

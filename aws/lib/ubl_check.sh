#!/usr/bin/env bash
# aws/lib/ubl_check.sh — Validate the Deadline Cloud UBL endpoint and Secrets Manager secret
# Purpose: Discover the UBL (Usage-Based Licensing) endpoint in the Portal VPC and
#          validate the Secrets Manager secret that points to it.
# Sourced by prepare_portal_region.sh; also runnable standalone.

set -euo pipefail

# ── AWS CLI path ──────────────────────────────────────────────────────────────
# uv-installed AWS CLI may not be on PATH; prefer it if found
AWS_CLI="/home/aoin/.cache/uv/archive-v0/FXuFsIxiijforE87cox8l/bin/aws"
if [[ -x "$AWS_CLI" ]]; then
    PATH="/home/aoin/.cache/uv/archive-v0/FXuFsIxiijforE87cox8l/bin:$PATH"
fi

# ── Internal helpers ──────────────────────────────────────────────────────────

# Print an error message to stderr and return 1.
_uc_die() {
    echo "ERROR: $*" >&2
    return 1
}

# Execute an AWS CLI command (or dry-run print it to stderr).
# Usage: _uc_aws ARGS...
# Returns: JSON string on stdout when not in dry-run; nothing on stdout in dry-run.
_uc_aws() {
    if [[ "${_UC_DRY_RUN:-0}" == "1" ]]; then
        echo "aws $*" >&2
        return 0
    fi
    aws "$@"
}

# Helper: emit one TSV row.
# Usage: _uc_row CHECK_NAME VALUE STATUS RESOURCE_KEY
_uc_row() {
    local check_name="$1"
    local value="$2"
    local status="$3"
    local resource_key="$4"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$_UC_REGION" "$check_name" "$value" "$status" "$resource_key"
}

# Resolve a DNS name — try `host` first, fall back to `dig +short`.
# Returns 0 if resolvable, 1 otherwise.
_uc_dns_resolvable() {
    local dns_name="$1"
    if command -v host &>/dev/null; then
        host "$dns_name" &>/dev/null && return 0
    fi
    if command -v dig &>/dev/null; then
        dig +short "$dns_name" &>/dev/null && return 0
    fi
    return 1
}

# ── query_ubl_check ──────────────────────────────────────────────────────────
# Args:
#   --region REGION       (required) single AWS region
#   --vpc-id VPC_ID       (optional) Portal VPC ID to scope the search
#   --yes                 (optional) apply mode: create/update secret if missing/stale
#   --dry-run             (optional) print AWS CLI commands to stderr, exit 0
#   --header              (optional) add TSV header row
#
# Output: TSV to stdout — REGION, CHECK_NAME, VALUE, STATUS, RESOURCE_KEY
#         One line per check.
query_ubl_check() {
    local region=""
    local vpc_id=""
    local apply=0
    local dry_run=0
    local header=0

    # ── Parse arguments ───────────────────────────────────────────────────────
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --region)
                region="$2"
                shift 2
                ;;
            --vpc-id)
                vpc_id="$2"
                shift 2
                ;;
            --yes)
                apply=1
                shift
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

    # Export for _uc_aws helper; store region for _uc_row
    _UC_DRY_RUN="$dry_run"
    _UC_REGION="$region"

    local secret_name="houdini/license-endpoint-dns"

    # ── Optional header ───────────────────────────────────────────────────────
    if [[ "$header" -eq 1 ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "REGION" "CHECK_NAME" "VALUE" "STATUS" "RESOURCE_KEY"
    fi

    # ── Step 1: UBL endpoint discovery ────────────────────────────────────────
    # Track what we found: endpoint_id, endpoint_dns, endpoint_source, endpoint_status
    local endpoint_id=""
    local endpoint_dns=""
    local endpoint_source=""
    local endpoint_status="not_found"

    # --- 1a. CloudFormation stack outputs/parameters with license/ubl/endpoint keywords ---
    local cfn_json=""
    cfn_json="$(_uc_aws cloudformation describe-stacks \
        --region "$region" \
        --output json)" || {
        echo "WARNING: Failed to describe CloudFormation stacks in $region" >&2
        cfn_json='{"Stacks":[]}'
    }

    if [[ "$dry_run" -eq 1 ]]; then
        # Already printed the CFN command; print the remaining discovery commands
        echo "aws ec2 describe-instances --region $region --filters ${vpc_id:+Name=vpc-id,Values=$vpc_id} --output json" >&2
        echo "aws elbv2 describe-load-balancers --region $region --output json" >&2
        echo "aws secretsmanager describe-secret --region $region --secret-id $secret_name" >&2
        echo "aws secretsmanager get-secret-value --region $region --secret-id $secret_name" >&2
        return 0
    fi

    # Search CFN stack outputs for license/ubl/endpoint keywords
    local cfn_endpoint
    cfn_endpoint="$(echo "$cfn_json" | jq -r '
        [.Stacks // [] | .[] |
            (.Outputs // []) + (.Parameters // [])
        ] | flatten |
        map(select(
            (.OutputKey // .ParameterKey // "") |
            test("license|ubl|endpoint"; "i")
        )) |
        map(.OutputValue // .ParameterValue // "") |
        map(select(length > 0))[0] // ""
    ')" || true

    if [[ -n "$cfn_endpoint" ]]; then
        endpoint_id="$cfn_endpoint"
        endpoint_source="cloudformation"
    fi

    # --- 1b. EC2 instances with ubl/license in name/tags ---
    if [[ -z "$endpoint_id" ]]; then
        local ec2_filters=()
        if [[ -n "$vpc_id" ]]; then
            ec2_filters+=("Name=vpc-id,Values=$vpc_id")
        fi

        local ec2_json
        ec2_json="$(aws ec2 describe-instances \
            --region "$region" \
            "${ec2_filters[@]}" \
            --output json 2>/dev/null)" || {
            ec2_json='{"Reservations":[]}'
        }

        # Find instances with "ubl" or "license" in Name tag or instance-id
        local ec2_match
        ec2_match="$(echo "$ec2_json" | jq -r '
            [.Reservations | .[] | .Instances | .[] |
                select(
                    ((.Tags // []) | map(select(.Key == "Name")) | .[].Value // ""
                        | test("ubl|license"; "i"))
                    or
                    (.InstanceId // "" | test("ubl|license"; "i"))
                )
            ][0] // null
        ')" || true

        if [[ "$ec2_match" != "null" && -n "$ec2_match" ]]; then
            endpoint_id="$(echo "$ec2_match" | jq -r '.InstanceId // ""')"
            endpoint_source="ec2"

            # Get instance state
            local instance_state
            instance_state="$(echo "$ec2_match" | jq -r '.State.Name // "unknown"')"
            if [[ "$instance_state" == "running" ]]; then
                endpoint_status="ready"
            elif [[ "$instance_state" == "stopped" ]]; then
                endpoint_status="stopped"
            else
                endpoint_status="$instance_state"
            fi

            # Get private DNS name
            endpoint_dns="$(echo "$ec2_match" | jq -r '.PrivateDnsName // ""')"
        fi
    fi

    # --- 1c. NLB/ELB with ubl/license in name ---
    if [[ -z "$endpoint_id" ]]; then
        local elbv2_json
        elbv2_json="$(aws elbv2 describe-load-balancers \
            --region "$region" \
            --output json 2>/dev/null)" || {
            elbv2_json='{"LoadBalancers":[]}'
        }

        # Filter to VPC if specified, and match name containing ubl/license
        local lb_match
        if [[ -n "$vpc_id" ]]; then
            lb_match="$(echo "$elbv2_json" | jq -r "
                [.LoadBalancers // [] | .[] |
                    select(
                        (.VpcId // \"\") == \"$vpc_id\"
                        and
                        ((.LoadBalancerName // \"\") | test(\"ubl|license\"; \"i\"))
                    )
                ][0] // null
            ")" || true
        else
            lb_match="$(echo "$elbv2_json" | jq -r '
                [.LoadBalancers // [] | .[] |
                    select(
                        (.LoadBalancerName // "") | test("ubl|license"; "i")
                    )
                ][0] // null
            ')" || true
        fi

        if [[ "$lb_match" != "null" && -n "$lb_match" ]]; then
            endpoint_id="$(echo "$lb_match" | jq -r '.LoadBalancerArn // ""')"
            endpoint_source="nlb"
            endpoint_dns="$(echo "$lb_match" | jq -r '.DNSName // ""')"

            # Check NLB state — active = ready
            local lb_state
            lb_state="$(echo "$lb_match" | jq -r '.State.Code // "unknown"')"
            if [[ "$lb_state" == "active" ]]; then
                endpoint_status="ready"
            else
                endpoint_status="$lb_state"
            fi
        fi
    fi

    # If we found via CFN but haven't determined status yet, attempt EC2 lookup
    if [[ -n "$endpoint_id" && "$endpoint_source" == "cloudformation" && -z "$endpoint_dns" ]]; then
        # The CFN output might be a DNS name itself
        if [[ "$endpoint_id" == *.compute.* || "$endpoint_id" == *.amazonaws.* ]]; then
            endpoint_dns="$endpoint_id"
            endpoint_status="ready"
        else
            # Try as an instance ID
            local ec2_instance_json
            ec2_instance_json="$(aws ec2 describe-instances \
                --region "$region" \
                --instance-ids "$endpoint_id" \
                --output json 2>/dev/null)" || {
                ec2_instance_json=''
            }
            if [[ -n "$ec2_instance_json" ]]; then
                local instance_state
                instance_state="$(echo "$ec2_instance_json" | jq -r '.Reservations[0].Instances[0].State.Name // "unknown"')"
                if [[ "$instance_state" == "running" ]]; then
                    endpoint_status="ready"
                elif [[ "$instance_state" == "stopped" ]]; then
                    endpoint_status="stopped"
                else
                    endpoint_status="$instance_state"
                fi
                endpoint_dns="$(echo "$ec2_instance_json" | jq -r '.Reservations[0].Instances[0].PrivateDnsName // ""')"
            fi
        fi
    fi

    # ── Step 1 output: ubl_endpoint ───────────────────────────────────────────
    _uc_row "ubl_endpoint" \
        "${endpoint_id:-none}" \
        "$endpoint_status" \
        "endpoint_id"

    # ── Step 2: Endpoint DNS reachability ─────────────────────────────────────
    if [[ -n "$endpoint_dns" ]]; then
        if _uc_dns_resolvable "$endpoint_dns"; then
            _uc_row "ubl_dns" "$endpoint_dns" "resolvable" "endpoint_dns"
        else
            _uc_row "ubl_dns" "$endpoint_dns" "unresolvable" "endpoint_dns"
        fi
    else
        _uc_row "ubl_dns" "none" "not_found" "endpoint_dns"
    fi

    # ── Step 3: Secrets Manager secret check ──────────────────────────────────
    local secret_exists=0
    local secret_value=""
    local secret_last_changed=""

    local describe_json
    describe_json="$(aws secretsmanager describe-secret \
        --region "$region" \
        --secret-id "$secret_name" \
        --output json 2>/dev/null)" || {
        describe_json=""
    }

    if [[ -n "$describe_json" ]]; then
        secret_exists=1
        _uc_row "ubl_secret" "$secret_name" "exists" "secret_name"

        # Get secret value
        local secret_value_json
        secret_value_json="$(aws secretsmanager get-secret-value \
            --region "$region" \
            --secret-id "$secret_name" \
            --output json 2>/dev/null)" || {
            secret_value_json=""
        }

        if [[ -n "$secret_value_json" ]]; then
            secret_value="$(echo "$secret_value_json" | jq -r '.SecretString // ""')"
        fi

        # Get last changed date
        secret_last_changed="$(echo "$describe_json" | jq -r '.LastChangedDate // .LastModifiedDate // ""')"
        if [[ -n "$secret_last_changed" ]]; then
            # Convert epoch or ISO to ISO 8601
            secret_last_changed="$(echo "$secret_last_changed" | jq -r 'if type == "number" then (. | todate) else . end' 2>/dev/null || echo "$secret_last_changed")"
        fi
    else
        _uc_row "ubl_secret" "$secret_name" "missing" "secret_name"
    fi

    # ── Step 4: Secret validation ─────────────────────────────────────────────
    if [[ "$secret_exists" -eq 1 && -n "$endpoint_dns" ]]; then
        # Compare secret value with actual endpoint DNS
        if [[ "$secret_value" == "$endpoint_dns" ]]; then
            _uc_row "ubl_secret_match" "$secret_value" "match" "secret_vs_endpoint"
        else
            _uc_row "ubl_secret_match" "$secret_value" "mismatch" "secret_vs_endpoint"
        fi
    elif [[ "$secret_exists" -eq 1 && -z "$endpoint_dns" ]]; then
        _uc_row "ubl_secret_match" "$secret_value" "no_endpoint" "secret_vs_endpoint"
    else
        _uc_row "ubl_secret_match" "none" "no_secret" "secret_vs_endpoint"
    fi

    # Check secret freshness (compare LastChangedDate with current time)
    if [[ "$secret_exists" -eq 1 && -n "$secret_last_changed" ]]; then
        _uc_row "ubl_secret_fresh" "$secret_last_changed" "fresh" "secret_last_changed"
    elif [[ "$secret_exists" -eq 1 ]]; then
        _uc_row "ubl_secret_fresh" "unknown" "fresh" "secret_last_changed"
    else
        _uc_row "ubl_secret_fresh" "none" "no_secret" "secret_last_changed"
    fi

    # ── Step 5: Apply mode — create/update secret if needed ───────────────────
    if [[ "$apply" -eq 1 && -n "$endpoint_dns" ]]; then
        if [[ "$secret_exists" -eq 0 ]]; then
            # Create the secret
            echo "NOTE: Creating secret $secret_name with endpoint DNS $endpoint_dns" >&2
            aws secretsmanager create-secret \
                --region "$region" \
                --name "$secret_name" \
                --secret-string "$endpoint_dns" \
                --output json >&2 || {
                echo "ERROR: Failed to create secret $secret_name" >&2
                return 1
            }
        elif [[ -n "$secret_value" && "$secret_value" != "$endpoint_dns" ]]; then
            # Update the stale secret
            echo "NOTE: Updating secret $secret_name: $secret_value -> $endpoint_dns" >&2
            aws secretsmanager put-secret-value \
                --region "$region" \
                --secret-id "$secret_name" \
                --secret-string "$endpoint_dns" \
                --output json >&2 || {
                echo "ERROR: Failed to update secret $secret_name" >&2
                return 1
            }
        fi
    elif [[ "$apply" -eq 1 && -z "$endpoint_dns" ]]; then
        echo "NOTE: No UBL endpoint DNS found; skipping secret creation (endpoint requires Deadline Cloud setup)." >&2
    fi
}

# ── Main guard: only run when executed directly ───────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    query_ubl_check "$@"
fi

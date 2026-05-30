#!/usr/bin/env bash
# aws/lib/quota_check.sh — Spot GPU quota headroom check per region
# Purpose: Checks Spot GPU quota limit and usage via AWS Service Quotas.
# Preconditions: AWS CLI installed, jq available, valid AWS credentials configured.
# Sourced by scan_gpu_capacity.sh; also runnable standalone.

set -euo pipefail

# ── AWS CLI path ──────────────────────────────────────────────────────────────
# uv-installed AWS CLI may not be on PATH; prefer it if found
AWS_CLI="/home/aoin/.cache/uv/archive-v0/FXuFsIxiijforE87cox8l/bin/aws"
if [[ -x "$AWS_CLI" ]]; then
    PATH="/home/aoin/.cache/uv/archive-v0/FXuFsIxiijforE87cox8l/bin:$PATH"
fi

# ── Internal helpers ──────────────────────────────────────────────────────────

# Derive the GPU family prefix from an instance type (e.g. g6.2xlarge -> g6).
_quota_family_from_type() {
    local instance_type="$1"
    echo "${instance_type%%.*}"
}

# Map a GPU family to its Spot quota code.
# All G-family Spot types share quota code L-74FC7D96.
_quota_code_for_family() {
    local family="$1"
    case "$family" in
        g5 | g6 | g6e)
            echo "L-74FC7D96"
            ;;
        *)
            echo ""
            ;;
    esac
}

# ── query_quota_check ─────────────────────────────────────────────────────────
# Args:
#   --region REGION              (required) single AWS region
#   --instance-types "T1 T2 …"  (required) space-separated list
#   --target-capacity N          (optional, default 1) instances needed
#   --dry-run                    (optional) print AWS CLI commands to stderr, exit 0
#   --header                     (optional) add TSV header row
#
# Output: TSV to stdout — REGION, QUOTA_NAME, QUOTA_CODE, USAGE, LIMIT, HEADROOM, STATUS
#         One line per unique (region, quota_code) pair.
query_quota_check() {
    local region=""
    local instance_types=""
    local target_capacity=1
    local dry_run=0
    local header=0

    # ── Parse arguments ───────────────────────────────────────────────────────
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --region)
                region="$2"
                shift 2
                ;;
            --instance-types)
                instance_types="$2"
                shift 2
                ;;
            --target-capacity)
                target_capacity="$2"
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
    if [[ -z "$instance_types" ]]; then
        echo "ERROR: --instance-types is required" >&2
        return 1
    fi

    # ── Collect unique quota codes from instance types ────────────────────────
    local type_array=()
    read -ra type_array <<< "$instance_types"

    # Associative array to deduplicate quota codes
    declare -A seen_quota_codes
    local quota_codes=()
    local t family qcode

    for t in "${type_array[@]}"; do
        family="$(_quota_family_from_type "$t")"
        qcode="$(_quota_code_for_family "$family")"
        if [[ -z "$qcode" ]]; then
            echo "WARNING: No Spot quota mapping for family '$family' (from $t), skipping." >&2
            continue
        fi
        if [[ -z "${seen_quota_codes[$qcode]+_}" ]]; then
            seen_quota_codes[$qcode]=1
            quota_codes+=("$qcode")
        fi
    done

    if [[ ${#quota_codes[@]} -eq 0 ]]; then
        echo "ERROR: No valid quota codes resolved from instance types." >&2
        return 1
    fi

    # ── Optional header ───────────────────────────────────────────────────────
    if [[ "$header" -eq 1 ]]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "REGION" "QUOTA_NAME" "QUOTA_CODE" "USAGE" "LIMIT" "HEADROOM" "STATUS"
    fi

    # ── Query each unique quota code ──────────────────────────────────────────
    local qc
    for qc in "${quota_codes[@]}"; do

        # ── Dry-run mode: print both commands and skip ────────────────────────
        if [[ "$dry_run" -eq 1 ]]; then
            echo "aws service-quotas get-service-quota --region $region --service-code ec2 --quota-code $qc" >&2
            echo "aws service-quotas list-service-quota-usage --region $region --service-code ec2 --quota-code $qc" >&2
            continue
        fi

        # ── Fetch quota limit ─────────────────────────────────────────────────
        local limit_json quota_name limit_value
        limit_json="$(aws service-quotas get-service-quota \
            --region "$region" \
            --service-code ec2 \
            --quota-code "$qc" \
            --output json 2>&1)" || {
            # NoSuchResourceException or similar — quota not visible in account
            if echo "$limit_json" | grep -q "NoSuchResourceException\|NoSuchResource\|ResourceNotFound"; then
                echo "NOTE: Spot quota $qc not visible in $region. May need to request access." >&2
                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$region" "N/A" "$qc" "0" "0" "0" "unknown"
                continue
            fi
            echo "ERROR: Failed to query quota $qc in $region: $limit_json" >&2
            return 1
        }

        limit_value="$(echo "$limit_json" | jq -r '.Quota.Value // 0')"
        quota_name="$(echo "$limit_json" | jq -r '.Quota.QuotaName // "Unknown"')"

        # ── Fetch quota usage ─────────────────────────────────────────────────
        local usage_value=0
        local usage_json
        usage_json="$(aws service-quotas list-service-quota-usage \
            --region "$region" \
            --service-code ec2 \
            --quota-code "$qc" \
            --output json 2>&1)" || {
            # list-service-quota-usage not available — fall back to 0 usage
            echo "NOTE: list-service-quota-usage unavailable for $qc in $region. Reporting USAGE=0, STATUS=unknown." >&2
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$region" "$quota_name" "$qc" "0" "$limit_value" "0" "unknown"
            continue
        }

        # Filter by quota code to get the correct usage entry
        usage_value="$(echo "$usage_json" \
            | jq -r --arg qc "$qc" \
                '[.QuotaUsages[] | select(.QuotaCode == $qc).UsedValue // 0][0] // 0')"

        # ── Compute headroom and status ───────────────────────────────────────
        local headroom
        headroom=$(( limit_value - usage_value ))

        local status
        if [[ "$headroom" -ge "$target_capacity" ]]; then
            status="ok"
        else
            status="low"
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$region" "$quota_name" "$qc" "$usage_value" "$limit_value" "$headroom" "$status"
    done

    # In dry-run mode, exit cleanly after printing commands
    if [[ "$dry_run" -eq 1 ]]; then
        return 0
    fi
}

# ── Main guard: only run when executed directly ───────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    query_quota_check "$@"
fi

#!/usr/bin/env bash
# aws/lib/spot_pricing.sh — Spot price history query per instance type per region
# Purpose: Reports min/max/avg Spot price ranges using describe-spot-price-history.
# Preconditions: AWS CLI installed, jq available, valid AWS credentials configured.
# Sourced by scan_gpu_capacity.sh; also runnable standalone.

set -euo pipefail

# ── AWS CLI path ──────────────────────────────────────────────────────────────
# uv-installed AWS CLI may not be on PATH; prefer it if found
AWS_CLI="/home/aoin/.cache/uv/archive-v0/FXuFsIxiijforE87cox8l/bin/aws"
if [[ -x "$AWS_CLI" ]]; then
    PATH="/home/aoin/.cache/uv/archive-v0/FXuFsIxiijforE87cox8l/bin:$PATH"
fi

# ── query_spot_pricing ────────────────────────────────────────────────────────
# Args:
#   --region REGION              (required) single AWS region
#   --instance-types "T1 T2 …"  (required) space-separated list
#   --product-description DESC   (optional, default "Linux/UNIX")
#   --hours N                    (optional, default 24) lookback window
#   --dry-run                    (optional) print AWS CLI command to stderr, exit 0
#   --header                     (optional) add TSV header row
#
# Output: TSV to stdout — REGION, INSTANCE_TYPE, MIN_PRICE, MAX_PRICE, AVG_PRICE,
#         DATA_POINT_COUNT. One line per requested instance type.
query_spot_pricing() {
    local region=""
    local instance_types=""
    local product_description="Linux/UNIX"
    local hours=24
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
            --product-description)
                product_description="$2"
                shift 2
                ;;
            --hours)
                hours="$2"
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

    # ── Compute start time ────────────────────────────────────────────────────
    local start_time
    start_time="$(date -u -d "${hours} hours ago" +%Y-%m-%dT%H:%M:%S)"

    # ── Convert instance_types string to array ────────────────────────────────
    local type_array=()
    read -ra type_array <<< "$instance_types"

    # ── Build instance-types display args for dry-run ──────────────────────────
    local it_args=()
    for t in "${type_array[@]}"; do
        it_args+=("$(printf '%q' "$t")")
    done

    # ── Dry-run mode ──────────────────────────────────────────────────────────
    if [[ "$dry_run" -eq 1 ]]; then
        echo "aws ec2 describe-spot-price-history --region $region --instance-types ${it_args[*]} --product-description \"$product_description\" --start-time \"$start_time\"" >&2
        return 0
    fi

    # ── Optional header ───────────────────────────────────────────────────────
    if [[ "$header" -eq 1 ]]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "REGION" "INSTANCE_TYPE" "MIN_PRICE" "MAX_PRICE" "AVG_PRICE" "DATA_POINT_COUNT"
    fi

    # ── Fetch spot price history with pagination ──────────────────────────────
    local all_json="[]"
    local next_token=""

    while true; do
        local cmd_args=(
            aws ec2 describe-spot-price-history
            --region "$region"
            --instance-types "${type_array[@]}"
            --product-description "$product_description"
            --start-time "$start_time"
            --output json
        )
        if [[ -n "$next_token" ]]; then
            cmd_args+=(--next-token "$next_token")
        fi

        local page_json
        page_json="$("${cmd_args[@]}")"

        # Append the SpotPriceHistory array from this page
        all_json="$(echo "$all_json" "$page_json" \
            | jq -s '.[0] + (.[1].SpotPriceHistory // [])')"

        # Check for NextToken
        next_token="$(echo "$page_json" | jq -r '.NextToken // empty')"
        if [[ -z "$next_token" ]]; then
            break
        fi
    done

    # ── Compute stats per instance type ───────────────────────────────────────
    local t
    for t in "${type_array[@]}"; do
        local stats
        stats="$(echo "$all_json" \
            | jq -r --arg type "$t" '
                map(select(.InstanceType == $type))
                | if length == 0 then
                    {min: "N/A", max: "N/A", avg: "N/A", count: 0}
                  else
                    (map(.SpotPrice | tonumber) | min) as $mn |
                    (map(.SpotPrice | tonumber) | max) as $mx |
                    (map(.SpotPrice | tonumber) | add / length) as $av |
                    {min: ($mn * 10000 | round / 10000 | tostring),
                     max: ($mx * 10000 | round / 10000 | tostring),
                     avg: ($av * 10000 | round / 10000 | tostring),
                     count: length}
                  end
            ')"

        local min_price max_price avg_price count
        min_price="$(echo "$stats" | jq -r '.min')"
        max_price="$(echo "$stats" | jq -r '.max')"
        avg_price="$(echo "$stats" | jq -r '.avg')"
        count="$(echo "$stats" | jq -r '.count')"

        # ── Flag $0.0000 prices ───────────────────────────────────────────────
        if [[ "$min_price" != "N/A" ]]; then
            if awk "BEGIN { exit !($min_price == 0) }"; then
                echo "WARNING: $t in $region returned \$0.00 — likely a Portal UI data gap, not free capacity." >&2
            fi
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$region" "$t" "$min_price" "$max_price" "$avg_price" "$count"
    done
}

# ── Main guard: only run when executed directly ───────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    query_spot_pricing "$@"
fi

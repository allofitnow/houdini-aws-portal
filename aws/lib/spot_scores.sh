#!/usr/bin/env bash
# aws/lib/spot_scores.sh — Spot placement score query library
# Queries AWS get-spot-placement-scores for a mixed instance pool across
# candidate regions and emits TSV to stdout.
# Source this file; defines functions only, no code on load.

# ── Internal helpers ──────────────────────────────────────────────────────────

# Print an error message to stderr and exit 1.
_spot_die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Default instance types when none are provided.
_SPOT_DEFAULT_INSTANCE_TYPES=(
    g6.2xlarge
    g6.4xlarge
    g6.8xlarge
    g6.16xlarge
    g6.24xlarge
)

# ── Public API ────────────────────────────────────────────────────────────────

# query_spot_scores [OPTIONS]
#
# Options:
#   --region REGION              (required) API endpoint region
#   --region-names R1 R2 ...     (optional, default: same as --region)
#   --instance-types T1 T2 ...   (required unless using defaults)
#   --target-capacity N          (optional, default: 1)
#   --dry-run                    (optional) print AWS CLI command to stderr, exit 0
#   --header                     (optional) add TSV header row
#
# Output: TSV to stdout — REGION, AVAILABILITY_ZONE_ID, SCORE
query_spot_scores() {
    local api_region=""
    local region_names=()
    local instance_types=()
    local target_capacity=1
    local dry_run=0
    local header=0

    # ── Parse arguments ───────────────────────────────────────────────────
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --region)
                [[ -z "${2:-}" ]] && _spot_die "--region requires a value"
                api_region="$2"
                shift 2
                ;;
            --region-names)
                [[ -z "${2:-}" ]] && _spot_die "--region-names requires a value"
                # shellcheck disable=SC2206
                region_names+=($2)
                shift 2
                ;;
            --instance-types)
                [[ -z "${2:-}" ]] && _spot_die "--instance-types requires a value"
                # shellcheck disable=SC2206
                instance_types+=($2)
                shift 2
                ;;
            --target-capacity)
                [[ -z "${2:-}" ]] && _spot_die "--target-capacity requires a value"
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
                _spot_die "unknown argument: $1"
                ;;
        esac
    done

    # ── Validate required arguments ───────────────────────────────────────
    if [[ -z "$api_region" ]]; then
        _spot_die "--region is required"
    fi

    # Default region-names to the API region
    if [[ ${#region_names[@]} -eq 0 ]]; then
        region_names=("$api_region")
    fi

    # Default instance types
    if [[ ${#instance_types[@]} -eq 0 ]]; then
        instance_types=("${_SPOT_DEFAULT_INSTANCE_TYPES[@]}")
    fi

    # ── Build the AWS CLI command ─────────────────────────────────────────
    local aws_cmd=(
        aws ec2 get-spot-placement-scores
        --region "$api_region"
        --region-names "${region_names[@]}"
        --instance-types "${instance_types[@]}"
        --target-capacity "$target_capacity"
        --single-availability-zone
    )

    # ── Dry-run mode ──────────────────────────────────────────────────────
    if [[ $dry_run -eq 1 ]]; then
        echo "${aws_cmd[*]}" >&2
        return 0
    fi

    # ── Execute the AWS CLI command ───────────────────────────────────────
    local response
    response=$("${aws_cmd[@]}") || _spot_die "AWS CLI command failed"

    # ── Optional header ───────────────────────────────────────────────────
    if [[ $header -eq 1 ]]; then
        printf '%s\t%s\t%s\n' "REGION" "AVAILABILITY_ZONE_ID" "SCORE"
    fi

    # ── Parse response and emit TSV ───────────────────────────────────────
    # Extract (Region, AvailabilityZoneId, Score) tuples from the response
    local scored_regions
    scored_regions=$(echo "$response" \
        | jq -r '.SpotPlacementScores[]? | "\(.Region)\t\(.AvailabilityZoneId)\t\(.Score)"')

    if [[ -n "$scored_regions" ]]; then
        echo "$scored_regions"
    fi

    # ── Emit N/A rows for regions with no scores ──────────────────────────
    # Collect regions that had scores returned
    local responded_regions
    responded_regions=$(echo "$response" \
        | jq -r '.SpotPlacementScores[]? | .Region' | sort -u)

    local rn_missing
    for rn in "${region_names[@]}"; do
        rn_missing=$(echo "$responded_regions" | grep -qxF "$rn" && echo "0" || echo "1")
        if [[ "$rn_missing" -eq 1 ]]; then
            printf '%s\t%s\t%s\n' "$rn" "N/A" "N/A"
        fi
    done
}

# ── Standalone execution ──────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    query_spot_scores "$@"
fi

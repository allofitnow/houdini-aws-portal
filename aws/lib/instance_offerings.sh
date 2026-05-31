#!/usr/bin/env bash
# aws/lib/instance_offerings.sh — Instance type offerings query
# Reports which instance types are offered in which regions and AZs.
# Sourced by scan_gpu_capacity.sh; also runnable standalone.
# No imports or external library dependencies.

# ── query_instance_offerings ──────────────────────────────────────────────────
# Query AWS EC2 instance-type-offerings for a set of instance types in a region.
#
# Usage:
#   query_instance_offerings --region REGION --instance-types "TYPE1 TYPE2 …"
#       [--dry-run] [--header]
#
# Options:
#   --region REGION          (required) single AWS region
#   --instance-types TYPES   (required) space-separated list of instance types
#   --dry-run                print the AWS CLI command to stderr, exit 0
#   --header                 emit a TSV header row before data
#
# Output: TSV to stdout, columns:
#   REGION  INSTANCE_TYPE  LOCATION_TYPE  LOCATION  OFFERED
#
# Types not offered anywhere in the region get a single row with
# LOCATION=ALL and OFFERED=no.

query_instance_offerings() {
    local region=""
    local instance_types=""
    local dry_run=0
    local header=0

    # ── Parse arguments ───────────────────────────────────────────────────
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
            --dry-run)
                dry_run=1
                shift
                ;;
            --header)
                header=1
                shift
                ;;
            *)
                echo "ERROR: unknown argument: $1" >&2
                return 1
                ;;
        esac
    done

    # ── Validate required arguments ───────────────────────────────────────
    if [[ -z "$region" ]]; then
        echo "ERROR: --region is required" >&2
        return 1
    fi
    if [[ -z "$instance_types" ]]; then
        echo "ERROR: --instance-types is required" >&2
        return 1
    fi

    local filter_values
    filter_values=${instance_types// /,}

    # ── Dry-run: print command and exit ───────────────────────────────────
    if (( dry_run )); then
        echo "aws ec2 describe-instance-type-offerings" \
             "--region ${region}" \
             "--location-type availability-zone" \
             "--filters \"Name=instance-type,Values=${filter_values}\"" >&2
        return 0
    fi

    # ── Header ────────────────────────────────────────────────────────────
    if (( header )); then
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "REGION" "INSTANCE_TYPE" "LOCATION_TYPE" "LOCATION" "OFFERED"
    fi

    # ── Collect all offerings via paginated API calls ─────────────────────
    local next_token=""
    local all_offerings=""

    while true; do
        local page_json
        if [[ -n "$next_token" ]]; then
            page_json=$(aws ec2 describe-instance-type-offerings \
                --region "$region" \
                --location-type availability-zone \
                --filters "Name=instance-type,Values=${filter_values}" \
                --starting-token "$next_token" \
                --output json 2>/dev/null)
        else
            page_json=$(aws ec2 describe-instance-type-offerings \
                --region "$region" \
                --location-type availability-zone \
                --filters "Name=instance-type,Values=${filter_values}" \
                --output json 2>/dev/null)
        fi

        # If the API returns nothing or fails, stop paginating
        if [[ -z "$page_json" ]]; then
            break
        fi

        # Extract the offerings array from this page
        local page_offerings
        page_offerings=$(echo "$page_json" | jq -c '.InstanceTypeOfferings // []')
        if [[ "$page_offerings" != "[]" ]]; then
            if [[ -n "$all_offerings" ]]; then
                all_offerings=$(printf '%s\n%s' "$all_offerings" "$page_offerings")
            else
                all_offerings="$page_offerings"
            fi
        fi

        # Check for NextToken to continue pagination
        next_token=$(echo "$page_json" | jq -r '.NextToken // empty')
        if [[ -z "$next_token" ]]; then
            break
        fi
    done

    # ── Track which instance types have been seen ─────────────────────────
    local -A seen_types

    # ── Parse offerings into TSV rows ─────────────────────────────────────
    if [[ -n "$all_offerings" ]]; then
        # Combine all page arrays into one and emit TSV rows
        local tsv_rows
        tsv_rows=$(printf '%s\n' "$all_offerings" | jq -r -s 'flatten | .[] |
            .InstanceType as $it |
            .Location as $loc |
            "\($it)\t\($loc)"')

        local itype loc
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            itype=$(echo "$line" | cut -f1)
            loc=$(echo "$line" | cut -f2)
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$region" "$itype" "availability-zone" "$loc" "yes"
            seen_types["$itype"]=1
        done <<< "$tsv_rows"
    fi

    # ── Emit OFFERED=no rows for types not found ──────────────────────────
    local req_type
    for req_type in $instance_types; do
        if [[ -z "${seen_types[$req_type]+x}" ]]; then
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$region" "$req_type" "availability-zone" "ALL" "no"
        fi
    done
}

# ── Standalone execution ──────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    query_instance_offerings "$@"
fi

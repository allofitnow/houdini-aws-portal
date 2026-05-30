#!/usr/bin/env bash
# aws/lib/ami_metadata.sh — AMI metadata and regional availability check
# Purpose: Checks whether the worker AMI exists in candidate regions and reports metadata.
# Sourced by scan_gpu_capacity.sh; also runnable standalone.
# No imports or external library dependencies.

# ── query_ami_metadata ────────────────────────────────────────────────────────
# Check AMI existence and metadata across regions using describe-images.
#
# Usage:
#   query_ami_metadata --regions REGION1,REGION2,... [OPTIONS]
#
# Options:
#   --regions REGIONS           (required) comma-separated list of regions
#   --source-region REGION      (optional, default us-west-2) source AMI region
#   --ami-id AMI_ID             (optional) specific AMI ID to check
#   --ami-name-pattern PATTERN  (optional, default deadline-*) prefix for wildcard search
#   --dry-run                   print AWS CLI commands to stderr, exit 0
#   --header                    add TSV header row
#
# Output: TSV to stdout, columns:
#   REGION  AMI_ID  ARCHITECTURE  PLATFORM  BOOT_MODE  VIRTUALIZATION  ROOT_DEVICE  STATUS
#
# STATUS is "exists" when the AMI is found, or "needs_copy_from:SOURCE_REGION" otherwise.

query_ami_metadata() {
    local regions_csv=""
    local source_region="us-west-2"
    local ami_id=""
    local ami_name_pattern="deadline-*"
    local dry_run=0
    local header=0

    # ── Parse arguments ───────────────────────────────────────────────────
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --regions)
                regions_csv="$2"
                shift 2
                ;;
            --source-region)
                source_region="$2"
                shift 2
                ;;
            --ami-id)
                ami_id="$2"
                shift 2
                ;;
            --ami-name-pattern)
                ami_name_pattern="$2"
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
    if [[ -z "$regions_csv" ]]; then
        echo "ERROR: --regions is required" >&2
        return 1
    fi

    # ── Convert comma-separated regions to array ──────────────────────────
    local -a regions=()
    IFS=',' read -ra regions <<< "$regions_csv"

    # ── Dry-run: print commands for each region and exit ──────────────────
    if (( dry_run )); then
        local r
        for r in "${regions[@]}"; do
            if [[ -n "$ami_id" ]]; then
                echo "aws ec2 describe-images --region $r --image-ids $ami_id" >&2
            else
                echo "aws ec2 describe-images --region $r --filters \"Name=name,Values=${ami_name_pattern}*\"" >&2
            fi
        done
        return 0
    fi

    # ── Header ────────────────────────────────────────────────────────────
    if (( header )); then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "REGION" "AMI_ID" "ARCHITECTURE" "PLATFORM" \
            "BOOT_MODE" "VIRTUALIZATION" "ROOT_DEVICE" "STATUS"
    fi

    # ── Query each region sequentially ────────────────────────────────────
    local r
    for r in "${regions[@]}"; do
        local json=""

        if [[ -n "$ami_id" ]]; then
            # Look up by specific AMI ID
            json=$(aws ec2 describe-images \
                --region "$r" \
                --image-ids "$ami_id" \
                --output json 2>/dev/null) || true
        else
            # Look up by name pattern (wildcard prefix match)
            json=$(aws ec2 describe-images \
                --region "$r" \
                --filters "Name=name,Values=${ami_name_pattern}*" \
                --output json 2>/dev/null) || true
        fi

        # Check if any images were returned
        local image_count=0
        if [[ -n "$json" ]]; then
            image_count=$(echo "$json" | jq -r '.Images // [] | length')
        fi

        if (( image_count > 0 )); then
            # Extract metadata from the first matching image
            local img_id arch platform boot_mode virt root_dev
            img_id=$(echo "$json" | jq -r '.Images[0].ImageId // "-"')
            arch=$(echo "$json" | jq -r '.Images[0].Architecture // "-"')
            platform=$(echo "$json" | jq -r '.Images[0].PlatformDetails // "-"')
            boot_mode=$(echo "$json" | jq -r '.Images[0].BootMode // "-"')
            virt=$(echo "$json" | jq -r '.Images[0].VirtualizationType // "-"')
            root_dev=$(echo "$json" | jq -r '.Images[0].RootDeviceType // "-"')

            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$r" "$img_id" "$arch" "$platform" \
                "$boot_mode" "$virt" "$root_dev" "exists"
        else
            # AMI not found in this region
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$r" "-" "-" "-" "-" "-" "-" "needs_copy_from:${source_region}"
        fi
    done
}

# ── Standalone execution ──────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    query_ami_metadata "$@"
fi

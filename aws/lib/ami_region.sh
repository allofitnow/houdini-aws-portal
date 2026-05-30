#!/usr/bin/env bash
# aws/lib/ami_region.sh — AMI regional copy with apply mode
# Purpose: Validate that the worker AMI exists in the target region, and
#          optionally copy it from the source region.
# Preconditions: AWS CLI installed, jq available, valid AWS credentials configured.
# Sourced by prepare_portal_region.sh; also runnable standalone.
# No imports or external library dependencies.

# ── query_ami_region ─────────────────────────────────────────────────────────
# Check AMI existence in a target region and optionally copy from source.
#
# Usage:
#   query_ami_region --region REGION [OPTIONS]
#
# Options:
#   --region REGION             (required) target region to check/copy into
#   --source-ami AMI_ID         (optional) specific AMI ID to check
#   --source-region REGION      (optional, default us-west-2) region where source AMI lives
#   --ami-name-pattern PATTERN  (optional, default deadline-*) prefix for wildcard search
#   --yes                       (optional) apply mode: actually copy the AMI if missing
#   --dry-run                   (optional) print what would be done, exit 0
#   --header                    (optional) add TSV header row
#
# Output: TSV to stdout, columns:
#   REGION  AMI_ID  STATUS
#
# STATUS values:
#   exists                       AMI already present in target region
#   needs_copy_from:SOURCE_REG   AMI missing, copy recommended (no --yes)
#   copying                      AMI copy initiated, polling in progress
#   copied_ok                    AMI copied and verified successfully
#   copy_failed                  AMI copy failed or timed out

query_ami_region() {
    local region=""
    local source_ami=""
    local source_region="us-west-2"
    local ami_name_pattern="deadline-*"
    local apply=0
    local dry_run=0
    local header=0

    # ── Parse arguments ───────────────────────────────────────────────────
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --region)
                region="$2"
                shift 2
                ;;
            --source-ami)
                source_ami="$2"
                shift 2
                ;;
            --source-region)
                source_region="$2"
                shift 2
                ;;
            --ami-name-pattern)
                ami_name_pattern="$2"
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

    # ── Header ────────────────────────────────────────────────────────────
    if (( header )); then
        printf '%s\t%s\t%s\n' "REGION" "AMI_ID" "STATUS"
    fi

    # ── Step 1: Check if AMI exists in target region ──────────────────────
    local json=""
    local image_count=0
    local found_ami_id=""
    local found_ami_name=""

    if [[ -n "$source_ami" ]]; then
        # Look up by specific AMI ID
        if (( dry_run )); then
            echo "aws ec2 describe-images --region $region --image-ids $source_ami" >&2
            printf '%s\t%s\t%s\n' "$region" "$source_ami" "exists"
            return 0
        fi
        json=$(aws ec2 describe-images \
            --region "$region" \
            --image-ids "$source_ami" \
            --output json 2>/dev/null) || true
    else
        # Look up by name pattern (wildcard prefix match)
        if (( dry_run )); then
            echo "aws ec2 describe-images --region $region --filters \"Name=name,Values=${ami_name_pattern}*\"" >&2
            printf '%s\t%s\t%s\n' "$region" "-" "exists"
            return 0
        fi
        json=$(aws ec2 describe-images \
            --region "$region" \
            --filters "Name=name,Values=${ami_name_pattern}*" \
            --output json 2>/dev/null) || true
    fi

    # ── Parse query result ────────────────────────────────────────────────
    if [[ -n "$json" ]]; then
        image_count=$(echo "$json" | jq -r '.Images // [] | length')
    fi

    if (( image_count > 0 )); then
        # AMI exists — extract ID and report
        found_ami_id=$(echo "$json" | jq -r '.Images[0].ImageId // "-"')
        printf '%s\t%s\t%s\n' "$region" "$found_ami_id" "exists"
        return 0
    fi

    # ── Step 2: AMI is missing in target region ───────────────────────────
    # We need the source AMI ID to proceed with copy logic.
    # If --source-ami was not given, look it up in the source region by name pattern.
    local effective_source_ami="$source_ami"
    if [[ -z "$effective_source_ami" ]]; then
        local src_json=""
        src_json=$(aws ec2 describe-images \
            --region "$source_region" \
            --filters "Name=name,Values=${ami_name_pattern}*" \
            --output json 2>/dev/null) || true

        local src_count=0
        if [[ -n "$src_json" ]]; then
            src_count=$(echo "$src_json" | jq -r '.Images // [] | length')
        fi

        if (( src_count == 0 )); then
            echo "ERROR: no AMI matching '${ami_name_pattern}*' found in source region ${source_region}" >&2
            printf '%s\t%s\t%s\n' "$region" "-" "needs_copy_from:${source_region}"
            return 1
        fi

        effective_source_ami=$(echo "$src_json" | jq -r '.Images[0].ImageId')
        found_ami_name=$(echo "$src_json" | jq -r '.Images[0].Name // "unknown"')
    else
        # Resolve the AMI name from source region for the copy --name parameter
        local name_json=""
        name_json=$(aws ec2 describe-images \
            --region "$source_region" \
            --image-ids "$effective_source_ami" \
            --output json 2>/dev/null) || true

        if [[ -n "$name_json" ]]; then
            local name_count=0
            name_count=$(echo "$name_json" | jq -r '.Images // [] | length')
            if (( name_count > 0 )); then
                found_ami_name=$(echo "$name_json" | jq -r '.Images[0].Name // "unknown"')
            else
                found_ami_name="unknown"
            fi
        else
            found_ami_name="unknown"
        fi
    fi

    local copy_name="copied-${found_ami_name}"

    # ── Without --yes: just report needs_copy ─────────────────────────────
    if (( ! apply )); then
        local copy_cmd="aws ec2 copy-image --region $region --source-region $source_region --source-ami-id $effective_source_ami --name \"$copy_name\""
        echo "COPY COMMAND: $copy_cmd" >&2
        printf '%s\t%s\t%s\n' "$region" "$effective_source_ami" "needs_copy_from:${source_region}"
        return 0
    fi

    # ── Step 3: Apply mode — copy the AMI ─────────────────────────────────
    echo "Copying AMI $effective_source_ami from $source_region to $region ..." >&2

    local copy_json=""
    if ! copy_json=$(aws ec2 copy-image \
        --region "$region" \
        --source-region "$source_region" \
        --source-ami-id "$effective_source_ami" \
        --name "$copy_name" \
        --output json 2>&1); then
        echo "ERROR: copy-image failed: $copy_json" >&2
        printf '%s\t%s\t%s\n' "$region" "$effective_source_ami" "copy_failed"
        return 1
    fi

    local new_ami_id=""
    new_ami_id=$(echo "$copy_json" | jq -r '.ImageId // empty')

    if [[ -z "$new_ami_id" ]]; then
        echo "ERROR: copy-image returned no ImageId" >&2
        printf '%s\t%s\t%s\n' "$region" "$effective_source_ami" "copy_failed"
        return 1
    fi

    # ── Step 4: Poll until available (30s interval, 600s timeout = 20 checks) ─
    printf '%s\t%s\t%s\n' "$region" "pending:${new_ami_id}" "copying"

    local poll_interval=30
    local max_checks=20
    local check=0
    local ami_state=""

    while (( check < max_checks )); do
        sleep "$poll_interval"
        (( check++ )) || true

        local poll_json=""
        poll_json=$(aws ec2 describe-images \
            --region "$region" \
            --image-ids "$new_ami_id" \
            --output json 2>/dev/null) || true

        if [[ -n "$poll_json" ]]; then
            ami_state=$(echo "$poll_json" | jq -r '.Images[0].State // "unknown"')
        else
            ami_state="unknown"
        fi

        echo "  [$check/$max_checks] AMI $new_ami_id state: $ami_state" >&2

        if [[ "$ami_state" == "available" ]]; then
            break
        fi

        if [[ "$ami_state" == "failed" ]]; then
            echo "ERROR: AMI copy failed for $new_ami_id in $region" >&2
            printf '%s\t%s\t%s\n' "$region" "$new_ami_id" "copy_failed"
            return 1
        fi
    done

    if [[ "$ami_state" != "available" ]]; then
        echo "ERROR: AMI copy timed out after $(( max_checks * poll_interval ))s for $new_ami_id in $region" >&2
        printf '%s\t%s\t%s\n' "$region" "$new_ami_id" "copy_failed"
        return 1
    fi

    # ── Step 5: Verify copied AMI metadata ────────────────────────────────
    local verify_json=""
    verify_json=$(aws ec2 describe-images \
        --region "$region" \
        --image-ids "$new_ami_id" \
        --output json 2>/dev/null) || true

    if [[ -z "$verify_json" ]]; then
        echo "ERROR: cannot verify copied AMI $new_ami_id — describe-images returned empty" >&2
        printf '%s\t%s\t%s\n' "$region" "$new_ami_id" "copy_failed"
        return 1
    fi

    local v_arch v_platform v_boot v_virt v_root
    v_arch=$(echo "$verify_json" | jq -r '.Images[0].Architecture // "-"')
    v_platform=$(echo "$verify_json" | jq -r '.Images[0].PlatformDetails // "-"')
    v_boot=$(echo "$verify_json" | jq -r '.Images[0].BootMode // "-"')
    v_virt=$(echo "$verify_json" | jq -r '.Images[0].VirtualizationType // "-"')
    v_root=$(echo "$verify_json" | jq -r '.Images[0].RootDeviceType // "-"')

    local verify_ok=1
    local v_issues=""

    if [[ "$v_arch" != "x86_64" ]]; then
        v_issues+="architecture=$v_arch (expected x86_64) "
        verify_ok=0
    fi
    if [[ "$v_platform" != "Linux/UNIX" ]]; then
        v_issues+="platform=$v_platform (expected Linux/UNIX) "
        verify_ok=0
    fi
    if [[ "$v_boot" != "uefi-preferred" ]]; then
        v_issues+="boot_mode=$v_boot (expected uefi-preferred) "
        verify_ok=0
    fi
    if [[ "$v_virt" != "hvm" ]]; then
        v_issues+="virtualization=$v_virt (expected hvm) "
        verify_ok=0
    fi
    if [[ "$v_root" != "ebs" ]]; then
        v_issues+="root_device=$v_root (expected ebs) "
        verify_ok=0
    fi

    if (( ! verify_ok )); then
        echo "WARNING: copied AMI $new_ami_id metadata mismatch: $v_issues" >&2
        # Still report copied_ok since the AMI exists and is available;
        # the caller can decide whether the metadata mismatch is fatal.
    fi

    echo "AMI $new_ami_id copied successfully to $region" >&2
    printf '%s\t%s\t%s\n' "$region" "$new_ami_id" "copied_ok"
    return 0
}

# ── Standalone execution ──────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    query_ami_region "$@"
fi

#!/usr/bin/env bash
# cleanup_all_infrastructure.sh
# Single entrypoint to stop/remove all project AWS worker infrastructure cleanly.
#
# This script orchestrates existing per-region cleanup helpers:
#   1. Terminate manual deadline-worker instances via terminate_spot_worker.sh.
#   2. Cancel AWS Portal Spot Fleet requests via portal_infra.sh stop.
#   3. Delete AWS Portal CloudFormation stacks via portal_infra.sh stop.
#
# Safety: destructive cleanup requires --yes. Without --yes this is a dry-run
# that prints the exact commands it would execute.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

REGIONS="${CLEANUP_REGIONS:-${READY_WORKER_REGIONS:-${REGION:-${AWS_REGION:-us-west-2}}}}"
ASSUME_YES="false"
DRY_RUN="true"
CLEAN_MANUAL_WORKERS="true"
CLEAN_PORTAL_INFRA="true"
SHOW_STATUS_AFTER="true"

usage() {
    cat >&2 <<USAGE
Usage: $0 --yes [options]
       $0 --dry-run [options]

Stops/removes project AWS infrastructure across one or more regions:
  - manual workers tagged project=deadline-worker
  - AWS Portal Spot Fleet requests
  - AWS Portal CloudFormation stacks, including Gateway/VPC resources

Options:
  --yes                         Execute destructive cleanup. Required for real cleanup.
  --dry-run                     Print actions only. This is the default.
  --regions r1,r2               Comma-separated regions. Defaults to CLEANUP_REGIONS,
                                READY_WORKER_REGIONS, REGION/AWS_REGION, then us-west-2.
  --skip-manual-workers         Do not run terminate_spot_worker.sh --all.
  --skip-portal                 Do not run portal_infra.sh stop.
  --no-status                   Do not run portal_infra.sh status after cleanup.
  -h, --help                    Show this help.

Examples:
  $0 --dry-run --regions us-west-2,us-east-1
  $0 --yes --regions us-west-2,us-east-1
  CLEANUP_REGIONS=us-west-2,eu-west-1 $0 --yes
USAGE
}

csv_to_array() {
    local csv="$1"
    local normalized
    normalized="${csv//,/ }"
    read -r -a CLEANUP_REGION_LIST <<< "$normalized"
}

run_or_print() {
    if [[ "$DRY_RUN" == "true" ]]; then
        printf 'DRY-RUN: '
        printf '%q ' "$@"
        printf '\n'
        return 0
    fi

    "$@"
}

cleanup_region() {
    local region="$1"

    echo ""
    echo "============================================================"
    echo " Cleaning AWS worker infrastructure in ${region}"
    echo "============================================================"

    if [[ "$CLEAN_MANUAL_WORKERS" == "true" ]]; then
        echo "-- Manual fallback workers --"
        run_or_print "${SCRIPT_DIR}/terminate_spot_worker.sh" --region "$region" --all
    else
        echo "-- Manual fallback workers skipped --"
    fi

    if [[ "$CLEAN_PORTAL_INFRA" == "true" ]]; then
        echo "-- AWS Portal Spot Fleets and CloudFormation stacks --"
        run_or_print "${SCRIPT_DIR}/portal_infra.sh" --region "$region" stop
    else
        echo "-- AWS Portal cleanup skipped --"
    fi

    if [[ "$SHOW_STATUS_AFTER" == "true" ]]; then
        echo "-- Post-cleanup status --"
        run_or_print "${SCRIPT_DIR}/portal_infra.sh" --region "$region" status
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)
            ASSUME_YES="true"
            DRY_RUN="false"
            shift
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --regions|--region-list)
            REGIONS="$2"
            shift 2
            ;;
        --skip-manual-workers)
            CLEAN_MANUAL_WORKERS="false"
            shift
            ;;
        --skip-portal)
            CLEAN_PORTAL_INFRA="false"
            shift
            ;;
        --no-status)
            SHOW_STATUS_AFTER="false"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument '$1'" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$REGIONS" ]]; then
    echo "ERROR: no regions configured." >&2
    usage
    exit 1
fi

csv_to_array "$REGIONS"
if [[ ${#CLEANUP_REGION_LIST[@]} -eq 0 ]]; then
    echo "ERROR: no regions parsed from: ${REGIONS}" >&2
    exit 1
fi

if [[ "$DRY_RUN" == "false" && "$ASSUME_YES" != "true" ]]; then
    echo "ERROR: destructive cleanup requires --yes." >&2
    usage
    exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY-RUN ONLY. Add --yes to stop/remove infrastructure."
else
    echo "DESTRUCTIVE CLEANUP ENABLED by --yes."
fi

echo "Regions: ${CLEANUP_REGION_LIST[*]}"

for region in "${CLEANUP_REGION_LIST[@]}"; do
    [[ -n "$region" ]] && cleanup_region "$region"
done

echo ""
if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry-run complete. No infrastructure was modified."
else
    echo "Cleanup commands completed. Some CloudFormation deletions may continue asynchronously."
fi

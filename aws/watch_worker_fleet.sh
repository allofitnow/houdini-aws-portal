#!/usr/bin/env bash
# aws/watch_worker_fleet.sh — Monitor active fleet fulfillment, EC2 worker state,
#                               boot logs, Deadline Worker registration, and UBL endpoint.
#                               Optional cancel and cleanup modes.
# Purpose: Single status snapshot (default), watch/poll, cancel, or cleanup.
# Preconditions: aws CLI, jq installed; valid AWS credentials configured.

set -euo pipefail

# ── Resolve script directory for library sourcing ─────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── AWS CLI path ──────────────────────────────────────────────────────────────
AWS_CLI="/home/aoin/.cache/uv/archive-v0/FXuFsIxiijforE87cox8l/bin/aws"
if [[ -x "$AWS_CLI" ]]; then
    PATH="/home/aoin/.cache/uv/archive-v0/FXuFsIxiijforE87cox8l/bin:$PATH"
fi

# ── Source libraries ──────────────────────────────────────────────────────────
# shellcheck source=lib/state.sh
source "${SCRIPT_DIR}/lib/state.sh"
# shellcheck source=lib/fsm_labels.sh
source "${SCRIPT_DIR}/lib/fsm_labels.sh"
# shellcheck source=lib/issue_log.sh
source "${SCRIPT_DIR}/lib/issue_log.sh"
# shellcheck source=lib/ubl_check.sh
source "${SCRIPT_DIR}/lib/ubl_check.sh"
# shellcheck source=lib/fleet_resources.sh
source "${SCRIPT_DIR}/lib/fleet_resources.sh"

# ── Constants ─────────────────────────────────────────────────────────────────
readonly WATCH_INTERVAL=60
readonly MAX_POLL_COUNT=120

# ── Temp file cleanup ─────────────────────────────────────────────────────────
declare -a _TMP_FILES=()
_cleanup() {
    local f
    for f in "${_TMP_FILES[@]+"${_TMP_FILES[@]}"}"; do
        rm -f "$f"
    done
}
trap _cleanup EXIT

_make_temp() {
    local t
    t=$(mktemp)
    _TMP_FILES+=("$t")
    echo "$t"
}

# ── Dependency check ──────────────────────────────────────────────────────────
_check_deps() {
    local missing=0
    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq is not installed" >&2
        missing=1
    fi
    if ! command -v aws &>/dev/null; then
        echo "ERROR: aws CLI is not installed" >&2
        missing=1
    fi
    if (( missing )); then
        exit 2
    fi
}

# ── Usage ─────────────────────────────────────────────────────────────────────
_usage() {
    cat <<EOF
Usage: $(basename "$0") \\
  --region REGION \\
  --fleet-request-id FLEET_ID \\
  [--watch] \\
  [--cancel] \\
  [--cleanup] \\
  [--yes] \\
  [--json] \\
  [--workflow-issue IID]

Modes (mutually exclusive):
  (default)   Single status snapshot, update GitLab issue, exit
  --watch     Poll every ${WATCH_INTERVAL}s until terminal state
  --cancel    Cancel the fleet request (requires --yes)
  --cleanup   Cancel + terminate instances + verify no orphans (requires --yes)

Options:
  --region REGION           AWS region (required)
  --fleet-request-id ID     Fleet request ID (required, unless --cleanup)
  --yes                     Skip confirmation prompts
  --json                    Output status as JSON
  --workflow-issue IID      GitLab issue IID for workflow state updates
EOF
}

# ══════════════════════════════════════════════════════════════════════════════
# Fleet status functions
# ══════════════════════════════════════════════════════════════════════════════

# _get_fleet_status REGION FLEET_ID
# Sets globals: FLEET_TYPE, FLEET_STATE, FLEET_REQUESTED, FLEET_FULFILLED,
#               INSTANCE_IDS (newline-separated)
_get_fleet_status() {
    local region="$1"
    local fleet_id="$2"

    FLEET_TYPE=""
    FLEET_STATE="unknown"
    FLEET_REQUESTED=0
    FLEET_FULFILLED=0
    INSTANCE_IDS=""

    # Try EC2 Fleet first
    local ec2_fleet_json
    ec2_fleet_json=$(aws ec2 describe-fleets \
        --region "$region" \
        --fleet-ids "$fleet_id" \
        --output json 2>/dev/null) || ec2_fleet_json=""

    if [[ -n "$ec2_fleet_json" ]]; then
        local fleet_count
        fleet_count=$(echo "$ec2_fleet_json" | jq '.Fleets | length')
        if [[ "$fleet_count" -gt 0 ]]; then
            FLEET_TYPE="ec2-fleet"
            FLEET_STATE=$(echo "$ec2_fleet_json" | jq -r '.Fleets[0].FleetState // "unknown"')
            FLEET_REQUESTED=$(echo "$ec2_fleet_json" | jq -r '.Fleets[0].TargetCapacitySpecification.TotalTargetCapacity // 0')
            FLEET_FULFILLED=$(echo "$ec2_fleet_json" | jq -r '.Fleets[0].FulfilledCapacity // 0')

            # Get launched instance IDs
            local instances_json
            instances_json=$(aws ec2 describe-fleet-instances \
                --region "$region" \
                --fleet-id "$fleet_id" \
                --output json 2>/dev/null) || instances_json='{"ActiveInstances":[]}'

            INSTANCE_IDS=$(echo "$instances_json" | jq -r '.ActiveInstances[].InstanceId // empty')
            return 0
        fi
    fi

    # Fall back to Spot Fleet
    local spot_fleet_json
    spot_fleet_json=$(aws ec2 describe-spot-fleet-requests \
        --region "$region" \
        --spot-fleet-request-ids "$fleet_id" \
        --output json 2>/dev/null) || spot_fleet_json=""

    if [[ -n "$spot_fleet_json" ]]; then
        local sf_count
        sf_count=$(echo "$spot_fleet_json" | jq '.SpotFleetRequestConfigs | length')
        if [[ "$sf_count" -gt 0 ]]; then
            FLEET_TYPE="spot-fleet"
            FLEET_STATE=$(echo "$spot_fleet_json" | jq -r '.SpotFleetRequestConfigs[0].SpotFleetRequestState // "unknown"')
            FLEET_REQUESTED=$(echo "$spot_fleet_json" | jq -r '.SpotFleetRequestConfigs[0].SpotFleetRequestConfig.TargetCapacity // 0')
            FLEET_FULFILLED=$(echo "$spot_fleet_json" | jq -r '.SpotFleetRequestConfigs[0].ActivityStatus // "unknown"')

            # For Spot Fleet, get fulfilled count from instance list
            local sf_instances_json
            sf_instances_json=$(aws ec2 describe-spot-fleet-instances \
                --region "$region" \
                --spot-fleet-request-id "$fleet_id" \
                --output json 2>/dev/null) || sf_instances_json='{"ActiveInstances":[]}'

            INSTANCE_IDS=$(echo "$sf_instances_json" | jq -r '.ActiveInstances[].InstanceId // empty')
            local instance_count
            instance_count=$(echo "$sf_instances_json" | jq '.ActiveInstances | length')
            FLEET_FULFILLED=$instance_count
            return 0
        fi
    fi

    echo "WARNING: Fleet $fleet_id not found as EC2 Fleet or Spot Fleet in $region" >&2
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# Instance state functions
# ══════════════════════════════════════════════════════════════════════════════

# _get_instance_states REGION INSTANCE_IDS_ARRAY
# Populates global INSTANCES_JSON array entries (one per instance)
# Each entry is a JSON object with id, type, state, private_ip, public_ip, launch_time
_get_instance_states() {
    local region="$1"
    shift
    local ids=("$@")

    INSTANCES_JSON=()

    if [[ ${#ids[@]} -eq 0 ]]; then
        return 0
    fi

    local desc_json
    desc_json=$(aws ec2 describe-instances \
        --region "$region" \
        --instance-ids "${ids[@]}" \
        --output json 2>/dev/null) || desc_json='{"Reservations":[]}'

    local count
    count=$(echo "$desc_json" | jq '.Reservations | length')
    if [[ "$count" -eq 0 ]]; then
        return 0
    fi

    # Build per-instance JSON objects
    local i
    for (( i = 0; i < count; i++ )); do
        local inst_json
        inst_json=$(echo "$desc_json" | jq -r --argjson idx "$i" '
            .Reservations[$idx].Instances[0] |
            {
                id: .InstanceId,
                type: .InstanceType,
                state: .State.Name,
                private_ip: (.PrivateIpAddress // null),
                public_ip: (.PublicIpAddress // null),
                launch_time: .LaunchTime
            }
        ')
        INSTANCES_JSON+=("$inst_json")
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# Boot log check
# ══════════════════════════════════════════════════════════════════════════════

# _check_boot_log REGION INSTANCE_ID
# Prints boot status summary string
_check_boot_log() {
    local region="$1"
    local instance_id="$2"

    local console_output
    console_output=$(aws ec2 get-console-output \
        --region "$region" \
        --instance-id "$instance_id" \
        --output text 2>/dev/null) || {
        echo "no console output available"
        return 0
    }

    if [[ -z "$console_output" ]]; then
        echo "no console output available"
        return 0
    fi

    # Check for cloud-init completion
    if echo "$console_output" | grep -qi "cloud-init.*finished\|Cloud-init.*complete\|modules-final.*done"; then
        echo "cloud-init completed"
        return 0
    fi

    # Check for Deadline indicators
    if echo "$console_output" | grep -qi "deadlinecommand\|Deadline.*Worker\|deadline.*slave"; then
        echo "Deadline bootstrap in progress"
        return 0
    fi

    # Check for error patterns
    if echo "$console_output" | grep -qi "error:\|failed:\|panic:\|Traceback\|EXCEPTION"; then
        echo "boot errors detected"
        return 0
    fi

    echo "cloud-init still running"
}

# ══════════════════════════════════════════════════════════════════════════════
# Deadline Worker registration check
# ══════════════════════════════════════════════════════════════════════════════

# _check_deadline_registration INSTANCE_PRIVATE_IP
# Prints registration status string; sets DEADLINE_REGISTERED=1 if confirmed
_check_deadline_registration() {
    local instance_ip="$1"
    DEADLINE_REGISTERED=0

    if ! command -v deadlinecommand &>/dev/null; then
        echo "deadlinecommand not available — manual check required"
        return 0
    fi

    local slaves_output
    slaves_output=$(deadlinecommand -GetSlaves 2>/dev/null) || {
        echo "deadlinecommand failed — cannot query"
        return 0
    }

    if [[ -z "$slaves_output" ]]; then
        echo "no workers registered"
        return 0
    fi

    # Try to find a worker matching this instance IP or a hostname derived from it
    local worker_name
    worker_name=$(echo "$slaves_output" | grep -i "$instance_ip" | head -n1) || true
    if [[ -z "$worker_name" ]]; then
        echo "not yet registered"
        return 0
    fi

    # shellcheck disable=SC2034
    DEADLINE_REGISTERED=1
    echo "registered as ${worker_name}"
}

# ══════════════════════════════════════════════════════════════════════════════
# UBL endpoint status
# ══════════════════════════════════════════════════════════════════════════════

# _get_ubl_status REGION
# Prints UBL status string; sets UBL_STATUS and UBL_RESOURCE globals
_get_ubl_status() {
    local region="$1"
    UBL_STATUS="unknown"
    UBL_RESOURCE=""

    local ubl_output
    ubl_output=$(query_ubl_check --region "$region" 2>/dev/null) || {
        UBL_STATUS="query failed"
        echo "query failed"
        return 0
    }

    # Parse TSV output — look for ubl_endpoint row
    local endpoint_line
    endpoint_line=$(echo "$ubl_output" | grep "ubl_endpoint" | head -n1) || true

    if [[ -n "$endpoint_line" ]]; then
        UBL_STATUS=$(echo "$endpoint_line" | awk -F'\t' '{print $4}')
        UBL_RESOURCE=$(echo "$endpoint_line" | awk -F'\t' '{print $3}')
    fi

    echo "${UBL_STATUS} (${UBL_RESOURCE:-none})"
}

# ══════════════════════════════════════════════════════════════════════════════
# FSM recommendation
# ══════════════════════════════════════════════════════════════════════════════

# _compute_fsm_recommendation
# Sets globals: FSM_TRANSITION, FSM_REASON
_compute_fsm_recommendation() {
    FSM_TRANSITION=""
    FSM_REASON=""

    local running_count=0
    # shellcheck disable=SC2034
    local total_instances=${#INSTANCE_IDS_ARRAY[@]}
    local all_deadline_registered=1

    for i in "${!INSTANCES_JSON[@]}"; do
        local state
        state=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.state')
        if [[ "$state" == "running" ]]; then
            (( running_count++ )) || true
        fi
    done

    # Check fleet failure
    if [[ "$FLEET_STATE" == "failed" || "$FLEET_STATE" == "failed_terminating" ]]; then
        FSM_TRANSITION="FLEET_REQUESTED → FAILED_CAPACITY"
        FSM_REASON="fleet state is ${FLEET_STATE}"
        return 0
    fi

    # Check if fleet was cancelled externally
    if [[ "$FLEET_STATE" == "cancelled"* ]]; then
        FSM_TRANSITION="Any → CANCELLED"
        FSM_REASON="fleet state is ${FLEET_STATE}"
        return 0
    fi

    # Check boot failures on running instances
    if [[ $running_count -gt 0 ]]; then
        for i in "${!BOOT_STATUSES[@]}"; do
            if [[ "${BOOT_STATUSES[$i]}" == "boot errors detected" ]]; then
                FSM_TRANSITION="FLEET_FULFILLED → FAILED_BOOT"
                FSM_REASON="instance boot errors detected"
                return 0
            fi
        done
    fi

    # Check if all requested instances are running
    if [[ $running_count -gt 0 && $running_count -ge $FLEET_REQUESTED ]]; then
        # Check if Deadline registered
        for i in "${!DEADLINE_STATUSES[@]}"; do
            if [[ "${DEADLINE_STATUSES[$i]}" != "registered as"* ]]; then
                all_deadline_registered=0
                break
            fi
        done

        if [[ $all_deadline_registered -eq 1 && ${#DEADLINE_STATUSES[@]} -gt 0 ]]; then
            FSM_TRANSITION="FLEET_FULFILLED → WORKER_REGISTERED"
            FSM_REASON="${running_count}/${FLEET_REQUESTED} instances running, Deadline registered"
        else
            FSM_TRANSITION="FLEET_REQUESTED → FLEET_FULFILLED"
            FSM_REASON="${running_count}/${FLEET_REQUESTED} instances running"
        fi
        return 0
    fi

    # Still in progress
    FSM_TRANSITION="FLEET_REQUESTED → (waiting)"
    FSM_REASON="${running_count}/${FLEET_REQUESTED} instances running"
}

# ══════════════════════════════════════════════════════════════════════════════
# Output formatting
# ══════════════════════════════════════════════════════════════════════════════

# _compute_uptime LAUNCH_TIME_ISO
# Prints human-readable uptime (e.g., "5m", "2h", "1d")
_compute_uptime() {
    local launch_time="$1"
    if [[ -z "$launch_time" || "$launch_time" == "null" ]]; then
        echo "n/a"
        return 0
    fi
    local now_epoch
    now_epoch=$(date +%s)
    local launch_epoch
    launch_epoch=$(date -d "$launch_time" +%s 2>/dev/null) || {
        echo "n/a"
        return 0
    }
    local diff=$(( now_epoch - launch_epoch ))
    if [[ $diff -lt 0 ]]; then diff=0; fi
    local minutes=$(( diff / 60 ))
    local hours=$(( minutes / 60 ))
    local days=$(( hours / 24 ))

    if [[ $days -gt 0 ]]; then
        echo "${days}d"
    elif [[ $hours -gt 0 ]]; then
        echo "${hours}h"
    else
        echo "${minutes}m"
    fi
}

_print_human_status() {
    echo "=== Fleet Status ==="
    echo "Fleet ID: ${FLEET_ID}"
    echo "Type: ${FLEET_TYPE:-unknown}"
    echo "State: ${FLEET_STATE}"
    echo "Requested: ${FLEET_REQUESTED}"
    echo "Fulfilled: ${FLEET_FULFILLED}"
    echo "Launched: ${#INSTANCE_IDS_ARRAY[@]}"
    echo ""

    echo "=== Instances ==="
    printf "%-20s %-15s %-12s %-18s %s\n" "ID" "Type" "State" "Private IP" "Uptime"
    for i in "${!INSTANCES_JSON[@]}"; do
        local id type state private_ip launch_time uptime
        id=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.id')
        type=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.type')
        state=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.state')
        private_ip=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.private_ip // "n/a"')
        launch_time=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.launch_time // ""')
        uptime=$(_compute_uptime "$launch_time")
        printf "%-20s %-15s %-12s %-18s %s\n" "$id" "$type" "$state" "$private_ip" "$uptime"
    done
    echo ""

    echo "=== Boot Status ==="
    for i in "${!BOOT_STATUSES[@]}"; do
        local id
        id=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.id')
        echo "${id}: ${BOOT_STATUSES[$i]}"
    done
    echo ""

    echo "=== UBL Endpoint ==="
    echo "${UBL_STATUS_LINE}"
    echo ""

    echo "=== Deadline Worker ==="
    for i in "${!DEADLINE_STATUSES[@]}"; do
        local id
        id=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.id')
        echo "${id}: ${DEADLINE_STATUSES[$i]}"
    done
    echo ""

    echo "=== FSM Recommendation ==="
    echo "${FSM_TRANSITION} (${FSM_REASON})"
}

_print_json_status() {
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build instances JSON array
    local instances_arr="[]"
    if [[ ${#INSTANCES_JSON[@]} -gt 0 ]]; then
        instances_arr="["
        for i in "${!INSTANCES_JSON[@]}"; do
            local id boot_status deadline_registered
            id=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.id')
            boot_status="${BOOT_STATUSES[$i]:-unknown}"
            deadline_registered="false"
            [[ "${DEADLINE_STATUSES[$i]:-}" == "registered as"* ]] && deadline_registered="true"

            local inst_enriched
            inst_enriched=$(echo "${INSTANCES_JSON[$i]}" | jq \
                --arg bs "$boot_status" \
                --argjson dr "$deadline_registered" \
                '. + {boot_status: $bs, deadline_registered: $dr}')

            if [[ $i -gt 0 ]]; then
                instances_arr+=","
            fi
            instances_arr+="$inst_enriched"
        done
        instances_arr+="]"
    fi

    local ubl_obj
    ubl_obj=$(jq -n --arg status "${UBL_STATUS}" \
        --arg resource "${UBL_RESOURCE:-none}" \
        '{status: $status, resource: $resource}')

    local fleet_obj
    fleet_obj=$(jq -n \
        --arg id "$FLEET_ID" \
        --arg type "${FLEET_TYPE:-unknown}" \
        --arg state "$FLEET_STATE" \
        --argjson requested "$FLEET_REQUESTED" \
        --argjson fulfilled "$FLEET_FULFILLED" \
        '{id: $id, type: $type, state: $state, requested: $requested, fulfilled: $fulfilled}')

    local recommendation_obj
    recommendation_obj=$(jq -n \
        --arg transition "$FSM_TRANSITION" \
        --arg reason "$FSM_REASON" \
        '{fsm_transition: $transition, reason: $reason}')

    jq -n \
        --arg timestamp "$timestamp" \
        --argjson fleet "$fleet_obj" \
        --argjson instances "$instances_arr" \
        --argjson ubl "$ubl_obj" \
        --argjson recommendation "$recommendation_obj" \
        '{
            timestamp: $timestamp,
            fleet: $fleet,
            instances: $instances,
            ubl: $ubl,
            recommendation: $recommendation
        }'
}

# ══════════════════════════════════════════════════════════════════════════════
# GitLab workflow helpers
# ══════════════════════════════════════════════════════════════════════════════

_workflow_update() {
    local issue_iid="$1"
    local new_state="$2"
    local reason="$3"

    if [[ -z "$issue_iid" ]]; then
        return 0
    fi

    # Write state
    local state_json
    state_json=$(jq -n \
        --arg fsm "$new_state" \
        --arg fleet_id "$FLEET_ID" \
        --arg region "$REGION" \
        '{fsm_state: $fsm, fleet_id: $fleet_id, region: $region}')

    state_write "$issue_iid" "$state_json" 2>/dev/null || true

    # FSM label transition
    fsm_transition "$issue_iid" "$new_state" 2>/dev/null || true

    # Inventory update
    local inventory_md
    inventory_md="**Fleet:** ${FLEET_ID} (${FLEET_TYPE:-unknown})\n"
    inventory_md+="**State:** ${FLEET_STATE}\n"
    inventory_md+="**Instances:** ${FLEET_FULFILLED}/${FLEET_REQUESTED}\n"
    for i in "${!INSTANCES_JSON[@]}"; do
        local id state priv_ip
        id=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.id')
        state=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.state')
        priv_ip=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.private_ip // "n/a"')
        inventory_md+="- ${id}: ${state} (${priv_ip})\n"
    done

    issue_update_inventory "$issue_iid" "$(echo -e "$inventory_md")" 2>/dev/null || true

    # Next action
    local next_action
    case "$new_state" in
        FLEET_FULFILLED)
            next_action="Verify Deadline Worker registration (run with --watch)"
            ;;
        WORKER_REGISTERED)
            next_action="Validate render job execution"
            ;;
        FAILED_CAPACITY)
            next_action="Review capacity errors, adjust instance types or region"
            ;;
        FAILED_BOOT)
            next_action="Check boot logs, review user-data and AMI"
            ;;
        CANCELLED)
            next_action="Run --cleanup to remove resources"
            ;;
        CLEANED_UP)
            next_action="Fleet fully cleaned up"
            ;;
        *)
            next_action="Monitor fleet status"
            ;;
    esac

    issue_update_next_action "$issue_iid" "$next_action" 2>/dev/null || true

    # Log
    issue_log "$issue_iid" "Status update: ${new_state} — ${reason}" 2>/dev/null || true
}

# ══════════════════════════════════════════════════════════════════════════════
# Cancel fleet
# ══════════════════════════════════════════════════════════════════════════════

_do_cancel() {
    local region="$1"
    local fleet_id="$2"
    local fleet_type="$3"

    echo "Cancelling fleet $fleet_id ..." >&2

    if [[ "$fleet_type" == "ec2-fleet" ]]; then
        aws ec2 delete-fleets \
            --region "$region" \
            --fleet-ids "$fleet_id" \
            --terminate-instances \
            --output json 2>/dev/null || {
            echo "WARNING: Failed to cancel EC2 Fleet $fleet_id" >&2
            return 1
        }
    else
        aws ec2 cancel-spot-fleet-requests \
            --region "$region" \
            --spot-fleet-request-ids "$fleet_id" \
            --terminate-instances \
            --output json 2>/dev/null || {
            echo "WARNING: Failed to cancel Spot Fleet $fleet_id" >&2
            return 1
        }
    fi

    echo "Fleet cancellation requested." >&2
}

# ══════════════════════════════════════════════════════════════════════════════
# Cleanup
# ══════════════════════════════════════════════════════════════════════════════

_do_cleanup() {
    local region="$1"
    local fleet_id="$2"
    local fleet_type="$3"

    echo "=== Cleanup ===" >&2

    # Step 1: Cancel fleet (idempotent)
    echo "Step 1: Cancelling fleet (if not already cancelled)..." >&2
    _do_cancel "$region" "$fleet_id" "$fleet_type" 2>/dev/null || true

    # Step 2: Terminate any remaining instances
    echo "Step 2: Terminating remaining instances..." >&2
    local ids=("${INSTANCE_IDS_ARRAY[@]+"${INSTANCE_IDS_ARRAY[@]}"}")
    if [[ ${#ids[@]} -gt 0 ]]; then
        # Re-query to see which are still alive
        local still_alive=()
        for id in "${ids[@]}"; do
            local inst_state
            inst_state=$(aws ec2 describe-instances \
                --region "$region" \
                --instance-ids "$id" \
                --output json 2>/dev/null | jq -r '.Reservations[0].Instances[0].State.Name // "terminated"') || inst_state="terminated"
            if [[ "$inst_state" != "terminated" && "$inst_state" != "shutting-down" ]]; then
                still_alive+=("$id")
            fi
        done

        if [[ ${#still_alive[@]} -gt 0 ]]; then
            echo "Terminating instances: ${still_alive[*]}" >&2
            aws ec2 terminate-instances \
                --region "$region" \
                --instance-ids "${still_alive[@]}" \
                --output json 2>/dev/null || {
                echo "WARNING: Failed to terminate some instances" >&2
            }
        else
            echo "No running instances to terminate." >&2
        fi
    else
        echo "No instances to terminate." >&2
    fi

    # Step 3: Verify no orphans with Portal tags
    echo "Step 3: Checking for orphan Portal instances..." >&2
    local orphans_json
    orphans_json=$(aws ec2 describe-instances \
        --region "$region" \
        --filters "Name=tag:Portal,Values=true" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --output json 2>/dev/null) || orphans_json='{"Reservations":[]}'

    local orphan_count
    orphan_count=$(echo "$orphans_json" | jq '[.Reservations[].Instances[]] | length')

    if [[ "$orphan_count" -gt 0 ]]; then
        echo "WARNING: Found ${orphan_count} orphan Portal instances:" >&2
        echo "$orphans_json" | jq -r '.Reservations[].Instances[] | "  \(.InstanceId) \(.State.Name) \(.InstanceType)"' >&2
    else
        echo "No orphan Portal instances found." >&2
    fi

    echo "" >&2
    echo "=== Cleanup Report ===" >&2
    echo "Fleet: ${fleet_id}" >&2
    echo "Cancelled: yes" >&2
    echo "Instances terminated: yes" >&2
    echo "Orphan Portal instances: ${orphan_count}" >&2
}

# ══════════════════════════════════════════════════════════════════════════════
# Single status snapshot
# ══════════════════════════════════════════════════════════════════════════════

_do_status_snapshot() {
    # Get fleet status
    _get_fleet_status "$REGION" "$FLEET_ID"

    # Build instance IDs array
    INSTANCE_IDS_ARRAY=()
    while IFS= read -r iid; do
        [[ -n "$iid" ]] && INSTANCE_IDS_ARRAY+=("$iid")
    done <<< "$INSTANCE_IDS"

    # Get instance states
    INSTANCES_JSON=()
    if [[ ${#INSTANCE_IDS_ARRAY[@]} -gt 0 ]]; then
        _get_instance_states "$REGION" "${INSTANCE_IDS_ARRAY[@]}"
    fi

    # Boot logs
    BOOT_STATUSES=()
    for i in "${!INSTANCES_JSON[@]}"; do
        local id state
        id=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.id')
        state=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.state')
        if [[ "$state" == "running" ]]; then
            BOOT_STATUSES+=("$(_check_boot_log "$REGION" "$id")")
        else
            BOOT_STATUSES+=("instance not running")
        fi
    done

    # UBL status
    UBL_STATUS_LINE=$(_get_ubl_status "$REGION")

    # Deadline registration
    DEADLINE_STATUSES=()
    for i in "${!INSTANCES_JSON[@]}"; do
        local state private_ip
        state=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.state')
        private_ip=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.private_ip // ""')
        if [[ "$state" == "running" && -n "$private_ip" ]]; then
            DEADLINE_STATUSES+=("$(_check_deadline_registration "$private_ip")")
        else
            DEADLINE_STATUSES+=("instance not running")
        fi
    done

    # FSM recommendation
    _compute_fsm_recommendation

    # Output
    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
        _print_json_status
    else
        _print_human_status
    fi

    # GitLab workflow update
    if [[ -n "$WORKFLOW_ISSUE" ]]; then
        # Determine target state from recommendation
        local target_state="FLEET_REQUESTED"
        if [[ "$FSM_TRANSITION" == *"FLEET_FULFILLED"* ]]; then
            target_state="FLEET_FULFILLED"
        elif [[ "$FSM_TRANSITION" == *"WORKER_REGISTERED"* ]]; then
            target_state="WORKER_REGISTERED"
        elif [[ "$FSM_TRANSITION" == *"FAILED_CAPACITY"* ]]; then
            target_state="FAILED_CAPACITY"
        elif [[ "$FSM_TRANSITION" == *"FAILED_BOOT"* ]]; then
            target_state="FAILED_BOOT"
        fi
        _workflow_update "$WORKFLOW_ISSUE" "$target_state" "$FSM_REASON"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Watch mode
# ══════════════════════════════════════════════════════════════════════════════

_do_watch() {
    echo "Watching fleet $FLEET_ID in $REGION (poll every ${WATCH_INTERVAL}s, max ${MAX_POLL_COUNT} iterations)..." >&2
    echo "" >&2

    local poll_count=0
    local terminal_state=""

    while [[ $poll_count -lt $MAX_POLL_COUNT ]]; do
        (( poll_count++ )) || true

        # Gather status
        _get_fleet_status "$REGION" "$FLEET_ID"

        INSTANCE_IDS_ARRAY=()
        while IFS= read -r iid; do
            [[ -n "$iid" ]] && INSTANCE_IDS_ARRAY+=("$iid")
        done <<< "$INSTANCE_IDS"

        INSTANCES_JSON=()
        if [[ ${#INSTANCE_IDS_ARRAY[@]} -gt 0 ]]; then
            _get_instance_states "$REGION" "${INSTANCE_IDS_ARRAY[@]}"
        fi

        # Count running instances
        local running_count=0
        for i in "${!INSTANCES_JSON[@]}"; do
            local st
            st=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.state')
            if [[ "$st" == "running" ]]; then (( running_count++ )); fi
        done

        local ts
        ts=$(date +"%H:%M:%S")
        echo "[$ts] Fleet: ${FLEET_STATE}, Instances: ${running_count}/${FLEET_REQUESTED} running" >&2

        # Boot logs for running instances
        BOOT_STATUSES=()
        DEADLINE_STATUSES=()
        for i in "${!INSTANCES_JSON[@]}"; do
            local id state private_ip
            id=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.id')
            state=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.state')
            private_ip=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.private_ip // ""')

            if [[ "$state" == "running" ]]; then
                BOOT_STATUSES+=("$(_check_boot_log "$REGION" "$id")")
                DEADLINE_STATUSES+=("$(_check_deadline_registration "$private_ip")")
            else
                BOOT_STATUSES+=("instance not running")
                DEADLINE_STATUSES+=("instance not running")
            fi
        done

        # UBL status
        UBL_STATUS_LINE=$(_get_ubl_status "$REGION")

        # Compute recommendation
        _compute_fsm_recommendation

        # Check for terminal states
        # Fleet failed
        if [[ "$FLEET_STATE" == "failed" || "$FLEET_STATE" == "failed_terminating" ]]; then
            terminal_state="FAILED_CAPACITY"
            echo "[$ts] Terminal state: fleet failed" >&2
            break
        fi

        # Fleet cancelled
        if [[ "$FLEET_STATE" == "cancelled"* ]]; then
            terminal_state="CANCELLED"
            echo "[$ts] Terminal state: fleet cancelled" >&2
            break
        fi

        # Boot failure
        for bs in "${BOOT_STATUSES[@]+"${BOOT_STATUSES[@]}"}"; do
            if [[ "$bs" == "boot errors detected" ]]; then
                terminal_state="FAILED_BOOT"
                echo "[$ts] Terminal state: boot errors" >&2
                break 2
            fi
        done

        # All instances fulfilled
        if [[ $running_count -ge $FLEET_REQUESTED && $FLEET_REQUESTED -gt 0 ]]; then
            # Check if Deadline is registered
            local all_registered=1
            for ds in "${DEADLINE_STATUSES[@]+"${DEADLINE_STATUSES[@]}"}"; do
                if [[ "$ds" != "registered as"* ]]; then
                    all_registered=0
                    break
                fi
            done

            if [[ $all_registered -eq 1 && ${#DEADLINE_STATUSES[@]} -gt 0 ]]; then
                terminal_state="WORKER_REGISTERED"
                echo "[$ts] Terminal state: all workers registered" >&2
                break
            fi

            # Fleet fulfilled even if Deadline not yet seen
            if [[ $running_count -ge $FLEET_REQUESTED && -z "$terminal_state" ]]; then
                # Still waiting for Deadline, but fleet is fulfilled
                echo "[$ts] All instances running, waiting for Deadline registration..." >&2
            fi
        fi

        sleep "$WATCH_INTERVAL"
    done

    # Final snapshot
    echo "" >&2
    echo "=== Final Status ===" >&2
    _get_fleet_status "$REGION" "$FLEET_ID"
    INSTANCE_IDS_ARRAY=()
    while IFS= read -r iid; do
        [[ -n "$iid" ]] && INSTANCE_IDS_ARRAY+=("$iid")
    done <<< "$INSTANCE_IDS"
    INSTANCES_JSON=()
    if [[ ${#INSTANCE_IDS_ARRAY[@]} -gt 0 ]]; then
        _get_instance_states "$REGION" "${INSTANCE_IDS_ARRAY[@]}"
    fi
    BOOT_STATUSES=()
    DEADLINE_STATUSES=()
    for i in "${!INSTANCES_JSON[@]}"; do
        local id state private_ip
        id=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.id')
        state=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.state')
        private_ip=$(echo "${INSTANCES_JSON[$i]}" | jq -r '.private_ip // ""')
        if [[ "$state" == "running" ]]; then
            BOOT_STATUSES+=("$(_check_boot_log "$REGION" "$id")")
            DEADLINE_STATUSES+=("$(_check_deadline_registration "$private_ip")")
        else
            BOOT_STATUSES+=("instance not running")
            DEADLINE_STATUSES+=("instance not running")
        fi
    done
    UBL_STATUS_LINE=$(_get_ubl_status "$REGION")
    _compute_fsm_recommendation

    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
        _print_json_status
    else
        _print_human_status
    fi

    # Determine final state for workflow update
    if [[ -z "$terminal_state" ]]; then
        # Max polls reached — infer from recommendation
        if [[ "$FSM_TRANSITION" == *"FLEET_FULFILLED"* ]]; then
            terminal_state="FLEET_FULFILLED"
        elif [[ "$FSM_TRANSITION" == *"WORKER_REGISTERED"* ]]; then
            terminal_state="WORKER_REGISTERED"
        else
            terminal_state="FLEET_REQUESTED"
        fi
    fi

    if [[ -n "$WORKFLOW_ISSUE" ]]; then
        _workflow_update "$WORKFLOW_ISSUE" "$terminal_state" "$FSM_REASON"
    fi

    if [[ $poll_count -ge $MAX_POLL_COUNT && -z "$terminal_state" ]]; then
        echo "WARNING: Max poll count reached (${MAX_POLL_COUNT}). Fleet not in terminal state." >&2
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════

main() {
    _check_deps

    # ── Step 1: CLI parsing ───────────────────────────────────────────────────
    REGION=""
    FLEET_ID=""
    MODE_WATCH=0
    MODE_CANCEL=0
    MODE_CLEANUP=0
    AUTO_YES=0
    JSON_OUTPUT=0
    WORKFLOW_ISSUE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --region)
                REGION="$2"
                shift 2
                ;;
            --fleet-request-id)
                FLEET_ID="$2"
                shift 2
                ;;
            --watch)
                MODE_WATCH=1
                shift
                ;;
            --cancel)
                MODE_CANCEL=1
                shift
                ;;
            --cleanup)
                MODE_CLEANUP=1
                shift
                ;;
            --yes)
                AUTO_YES=1
                shift
                ;;
            --json)
                JSON_OUTPUT=1
                shift
                ;;
            --workflow-issue)
                WORKFLOW_ISSUE="$2"
                shift 2
                ;;
            -h|--help)
                _usage
                exit 0
                ;;
            *)
                echo "ERROR: Unknown argument: $1" >&2
                _usage >&2
                exit 1
                ;;
        esac
    done

    # Validate required args
    if [[ -z "$REGION" ]]; then
        echo "ERROR: --region is required" >&2
        _usage >&2
        exit 1
    fi

    # --cancel and --cleanup require --yes
    if [[ $MODE_CANCEL -eq 1 && $AUTO_YES -eq 0 ]]; then
        echo "ERROR: --cancel requires --yes" >&2
        exit 1
    fi
    if [[ $MODE_CLEANUP -eq 1 && $AUTO_YES -eq 0 ]]; then
        echo "ERROR: --cleanup requires --yes" >&2
        exit 1
    fi

    # Modes are mutually exclusive
    local mode_count=$(( MODE_WATCH + MODE_CANCEL + MODE_CLEANUP ))
    if [[ $mode_count -gt 1 ]]; then
        echo "ERROR: --watch, --cancel, and --cleanup are mutually exclusive" >&2
        exit 1
    fi

    # Fleet ID required except for --cleanup (which can discover or use stored state)
    # For --cleanup without fleet-id, we still need it; error out
    if [[ -z "$FLEET_ID" && $MODE_CANCEL -eq 1 ]]; then
        echo "ERROR: --fleet-request-id is required for --cancel" >&2
        exit 1
    fi
    if [[ -z "$FLEET_ID" && $MODE_CLEANUP -eq 0 && $MODE_WATCH -eq 0 ]]; then
        echo "ERROR: --fleet-request-id is required" >&2
        exit 1
    fi
    if [[ -z "$FLEET_ID" && $MODE_WATCH -eq 1 ]]; then
        echo "ERROR: --fleet-request-id is required for --watch" >&2
        exit 1
    fi

    # ── Dispatch mode ─────────────────────────────────────────────────────────

    if [[ $MODE_CLEANUP -eq 1 ]]; then
        # For cleanup, we need the fleet ID (from --fleet-request-id or from workflow state)
        if [[ -z "$FLEET_ID" && -n "$WORKFLOW_ISSUE" ]]; then
            FLEET_ID=$(state_get_field "$WORKFLOW_ISSUE" "fleet_id" 2>/dev/null) || FLEET_ID=""
        fi
        if [[ -z "$FLEET_ID" ]]; then
            echo "ERROR: --fleet-request-id is required for --cleanup (or --workflow-issue with stored state)" >&2
            exit 1
        fi

        # Get fleet type
        _get_fleet_status "$REGION" "$FLEET_ID"
        INSTANCE_IDS_ARRAY=()
        while IFS= read -r iid; do
            [[ -n "$iid" ]] && INSTANCE_IDS_ARRAY+=("$iid")
        done <<< "$INSTANCE_IDS"

        _do_cleanup "$REGION" "$FLEET_ID" "${FLEET_TYPE:-spot-fleet}"

        # Transition to CLEANED_UP
        if [[ -n "$WORKFLOW_ISSUE" ]]; then
            _workflow_update "$WORKFLOW_ISSUE" "CLEANED_UP" "Fleet cancelled, instances terminated, orphan check done"
        fi

        echo "" >&2
        echo "Cleanup complete." >&2
        return 0
    fi

    if [[ $MODE_CANCEL -eq 1 ]]; then
        _get_fleet_status "$REGION" "$FLEET_ID"
        _do_cancel "$REGION" "$FLEET_ID" "${FLEET_TYPE:-spot-fleet}"

        if [[ -n "$WORKFLOW_ISSUE" ]]; then
            _workflow_update "$WORKFLOW_ISSUE" "CANCELLED" "Operator cancelled fleet"
        fi

        echo "" >&2
        echo "Fleet cancellation submitted." >&2
        return 0
    fi

    if [[ $MODE_WATCH -eq 1 ]]; then
        _do_watch
        return 0
    fi

    # Default: single status snapshot
    _do_status_snapshot
}

main "$@"

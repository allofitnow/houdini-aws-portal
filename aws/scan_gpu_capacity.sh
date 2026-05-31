#!/usr/bin/env bash
# aws/scan_gpu_capacity.sh — GPU capacity scout: main orchestrator
# Purpose: Queries Spot scores, instance offerings, pricing, AMI availability, and
#          quotas across candidate regions; ranks regions; outputs recommendations.
# Preconditions: aws CLI, jq installed; valid AWS credentials configured.

set -euo pipefail

# ── Resolve script directory for library sourcing ─────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source libraries ──────────────────────────────────────────────────────────
# shellcheck source=aws/lib/spot_scores.sh
source "${SCRIPT_DIR}/lib/spot_scores.sh"
# shellcheck source=aws/lib/instance_offerings.sh
source "${SCRIPT_DIR}/lib/instance_offerings.sh"
# shellcheck source=aws/lib/spot_pricing.sh
source "${SCRIPT_DIR}/lib/spot_pricing.sh"
# shellcheck source=aws/lib/ami_metadata.sh
source "${SCRIPT_DIR}/lib/ami_metadata.sh"
# shellcheck source=aws/lib/quota_check.sh
source "${SCRIPT_DIR}/lib/quota_check.sh"
# shellcheck source=aws/lib/state.sh
source "${SCRIPT_DIR}/lib/state.sh"
# shellcheck source=aws/lib/fsm_labels.sh
source "${SCRIPT_DIR}/lib/fsm_labels.sh"
# shellcheck source=aws/lib/issue_log.sh
source "${SCRIPT_DIR}/lib/issue_log.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
DEFAULT_REGIONS="us-west-2,us-east-1,us-east-2"
DEFAULT_FAMILIES="g6"
DEFAULT_TARGET_CAPACITY=1
DEFAULT_SOURCE_AMI="ami-0f70342f66dc80ddb"
DEFAULT_SOURCE_REGION="us-west-2"

# ── Family → instance-type expansion map ──────────────────────────────────────
declare -A FAMILY_TYPES
FAMILY_TYPES[g6]="g6.2xlarge g6.4xlarge g6.8xlarge g6.16xlarge g6.24xlarge"
FAMILY_TYPES[g6e]="g6e.2xlarge g6e.4xlarge g6e.8xlarge g6e.16xlarge g6e.24xlarge"
FAMILY_TYPES[g5]="g5.2xlarge g5.4xlarge g5.8xlarge g5.16xlarge g5.24xlarge"

# ── Temp file cleanup ─────────────────────────────────────────────────────────
declare -a _TMP_FILES=()
_cleanup() {
    local f
    for f in "${_TMP_FILES[@]+"${_TMP_FILES[@]}"}"; do
        rm -f "$f"
    done
}
trap _cleanup EXIT

# Create a temp file and register it for cleanup.
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

# ── Main function ─────────────────────────────────────────────────────────────
main() {
    # ── CLI parsing ───────────────────────────────────────────────────────────
    local REGIONS_CSV=""
    local FAMILIES_CSV=""
    local TARGET_CAPACITY=""
    local SOURCE_AMI=""
    local SOURCE_REGION=""
    local DRY_RUN=0
    local JSON_OUTPUT=0
    local WORKFLOW_ISSUE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --regions)
                REGIONS_CSV="$2"
                shift 2
                ;;
            --families)
                FAMILIES_CSV="$2"
                shift 2
                ;;
            --target-capacity)
                TARGET_CAPACITY="$2"
                shift 2
                ;;
            --source-ami)
                SOURCE_AMI="$2"
                shift 2
                ;;
            --source-region)
                SOURCE_REGION="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
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
            *)
                echo "ERROR: unknown argument: $1" >&2
                exit 1
                ;;
        esac
    done

    # Apply defaults
    [[ -z "$REGIONS_CSV" ]] && REGIONS_CSV="$DEFAULT_REGIONS"
    [[ -z "$FAMILIES_CSV" ]] && FAMILIES_CSV="$DEFAULT_FAMILIES"
    [[ -z "$TARGET_CAPACITY" ]] && TARGET_CAPACITY="$DEFAULT_TARGET_CAPACITY"
    [[ -z "$SOURCE_AMI" ]] && SOURCE_AMI="$DEFAULT_SOURCE_AMI"
    [[ -z "$SOURCE_REGION" ]] && SOURCE_REGION="$DEFAULT_SOURCE_REGION"

    # ── Expand families into instance types ───────────────────────────────────
    local -a ALL_TYPES=()
    local -a _FAMILIES=()
    IFS=',' read -ra _FAMILIES <<< "$FAMILIES_CSV"

    local _fam
    for _fam in "${_FAMILIES[@]}"; do
        if [[ -z "${FAMILY_TYPES[$_fam]+x}" ]]; then
            echo "ERROR: unknown family '$_fam'. Supported: g5 g6 g6e" >&2
            exit 1
        fi
        # shellcheck disable=SC2206
        ALL_TYPES+=(${FAMILY_TYPES[$_fam]})
    done

    local ALL_TYPES_STR="${ALL_TYPES[*]}"

    # ── Parse regions into array ──────────────────────────────────────────────
    local -a REGIONS=()
    IFS=',' read -ra REGIONS <<< "$REGIONS_CSV"

    # ── Dry-run: print expanded args and exit ─────────────────────────────────
    if (( DRY_RUN )); then
        echo "Regions:        ${REGIONS[*]}"
        echo "Families:       ${_FAMILIES[*]}"
        echo "Instance types: ${ALL_TYPES[*]}"
        echo "Target capacity: ${TARGET_CAPACITY}"
        echo "Source AMI:     ${SOURCE_AMI}"
        echo "Source region:  ${SOURCE_REGION}"
        echo "Workflow issue: ${WORKFLOW_ISSUE:-none}"
        exit 0
    fi

    # ── Dependency check (after dry-run so dry-run works without deps) ────────
    _check_deps

    # ── Step 2: Call libraries sequentially ───────────────────────────────────
    local SPOT_SCORES_FILE OFFERINGS_FILE PRICING_FILE AMI_FILE QUOTA_FILE
    SPOT_SCORES_FILE=$(_make_temp)
    OFFERINGS_FILE=$(_make_temp)
    PRICING_FILE=$(_make_temp)
    AMI_FILE=$(_make_temp)
    QUOTA_FILE=$(_make_temp)

    echo "Scanning GPU capacity across ${#REGIONS[@]} region(s)..." >&2

    # AMI metadata: call once outside the region loop
    echo "  Querying AMI metadata..." >&2
    if ! query_ami_metadata \
        --regions "$REGIONS_CSV" \
        --source-region "$SOURCE_REGION" \
        --ami-id "$SOURCE_AMI" \
        --header \
        > "$AMI_FILE"; then
        echo "ERROR: AMI metadata query failed" >&2
        exit 1
    fi

    local _region
    for _region in "${REGIONS[@]}"; do
        echo "  Region: $_region" >&2

        # 1. Spot scores
        echo "    Querying spot placement scores..." >&2
        if ! query_spot_scores \
            --region "$_region" \
            --instance-types "$ALL_TYPES_STR" \
            --target-capacity "$TARGET_CAPACITY" \
            --header \
            >> "$SPOT_SCORES_FILE"; then
            echo "ERROR: Spot score query failed for $_region" >&2
            exit 1
        fi

        # 2. Instance offerings
        echo "    Querying instance offerings..." >&2
        if ! query_instance_offerings \
            --region "$_region" \
            --instance-types "$ALL_TYPES_STR" \
            --header \
            >> "$OFFERINGS_FILE"; then
            echo "ERROR: Instance offerings query failed for $_region" >&2
            exit 1
        fi

        # 3. Spot pricing
        echo "    Querying spot pricing..." >&2
        if ! query_spot_pricing \
            --region "$_region" \
            --instance-types "$ALL_TYPES_STR" \
            --header \
            >> "$PRICING_FILE"; then
            echo "ERROR: Spot pricing query failed for $_region" >&2
            exit 1
        fi

        # 5. Quota check
        echo "    Querying quota..." >&2
        if ! query_quota_check \
            --region "$_region" \
            --instance-types "$ALL_TYPES_STR" \
            --target-capacity "$TARGET_CAPACITY" \
            --header \
            >> "$QUOTA_FILE"; then
            echo "ERROR: Quota check failed for $_region" >&2
            exit 1
        fi
    done

    echo "Data collection complete. Merging and ranking..." >&2

    # ── Step 3: Merge and rank ────────────────────────────────────────────────

    # Parse AMI status per region (skip header)
    local -A AMI_EXISTS=()     # region → "yes" or "no"
    local -A AMI_ID_MAP=()     # region → ami_id
    local _a_region _a_ami _a_arch _a_plat _a_boot _a_virt _a_root _a_status
    while IFS=$'\t' read -r _a_region _a_ami _a_arch _a_plat _a_boot _a_virt _a_root _a_status; do
        [[ "$_a_region" == "REGION" ]] && continue
        if [[ "$_a_status" == "exists" ]]; then
            AMI_EXISTS[$_a_region]="yes"
            AMI_ID_MAP[$_a_region]="$_a_ami"
        else
            AMI_EXISTS[$_a_region]="no"
            AMI_ID_MAP[$_a_region]=""
        fi
    done < "$AMI_FILE"

    # Parse quota status per region (skip header)
    local -A QUOTA_STATUS=()    # region → "ok" or "low" or "unknown"
    local -A QUOTA_HEADROOM=()  # region → headroom value
    local _q_region _q_name _q_code _q_usage _q_limit _q_headroom _q_status
    while IFS=$'\t' read -r _q_region _q_name _q_code _q_usage _q_limit _q_headroom _q_status; do
        [[ "$_q_region" == "REGION" ]] && continue
        QUOTA_STATUS[$_q_region]="$_q_status"
        QUOTA_HEADROOM[$_q_region]="$_q_headroom"
    done < "$QUOTA_FILE"

    # Parse offerings per region/type (skip header).
    # Determine which types are offered in at least one AZ per region.
    local -A TYPE_OFFERED_IN_REGION=()  # "region:type" → "yes" or "no"
    local _o_region _o_type _o_loctype _o_loc _o_offered
    while IFS=$'\t' read -r _o_region _o_type _o_loctype _o_loc _o_offered; do
        [[ "$_o_region" == "REGION" ]] && continue
        local _okey="${_o_region}:${_o_type}"
        if [[ "$_o_offered" == "yes" ]]; then
            TYPE_OFFERED_IN_REGION[$_okey]="yes"
        elif [[ -z "${TYPE_OFFERED_IN_REGION[$_okey]+x}" ]]; then
            TYPE_OFFERED_IN_REGION[$_okey]="no"
        fi
    done < "$OFFERINGS_FILE"

    # Parse spot scores per (region, AZ) (skip header)
    local -a SCORE_ENTRIES=()
    local _s_region _s_az _s_score
    while IFS=$'\t' read -r _s_region _s_az _s_score; do
        [[ "$_s_region" == "REGION" ]] && continue
        SCORE_ENTRIES+=("$_s_region" "$_s_az" "$_s_score")
    done < "$SPOT_SCORES_FILE"

    # Parse spot pricing per region/type (skip header)
    local -A PRICING_MIN=()  # "region:type" → price
    local -A PRICING_MAX=()
    local -A PRICING_AVG=()
    local _p_region _p_type _p_min _p_max _p_avg _p_count
    while IFS=$'\t' read -r _p_region _p_type _p_min _p_max _p_avg _p_count; do
        [[ "$_p_region" == "REGION" ]] && continue
        local _pkey="${_p_region}:${_p_type}"
        PRICING_MIN[$_pkey]="$_p_min"
        PRICING_MAX[$_pkey]="$_p_max"
        PRICING_AVG[$_pkey]="$_p_avg"
    done < "$PRICING_FILE"

    # ── Build scored entries for each (region, AZ) pair ───────────────────────

    # Collect all (region, AZ) pairs from spot scores
    local -a SCORE_REGIONS=()
    local -a SCORE_AZS=()
    local -a SCORE_VALS=()
    local _idx=0
    while (( _idx < ${#SCORE_ENTRIES[@]} )); do
        SCORE_REGIONS+=("${SCORE_ENTRIES[$((_idx))]}")
        SCORE_AZS+=("${SCORE_ENTRIES[$((_idx + 1))]}")
        SCORE_VALS+=("${SCORE_ENTRIES[$((_idx + 2))]}")
        _idx=$((_idx + 3))
    done

    # For regions with no spot score entries at all, add a synthetic entry
    local _region
    for _region in "${REGIONS[@]}"; do
        local _has_entry=0
        local _i
        for _i in "${!SCORE_REGIONS[@]}"; do
            if [[ "${SCORE_REGIONS[$_i]}" == "$_region" ]]; then
                _has_entry=1
                break
            fi
        done
        if (( !_has_entry )); then
            SCORE_REGIONS+=("$_region")
            SCORE_AZS+=("N/A")
            SCORE_VALS+=("0")
        fi
    done

    # Compute composite scores
    local -a RANK_REGIONS=()
    local -a RANK_AZS=()
    local -a RANK_COMPOSITE=()
    local -a RANK_SPOT_SCORE=()
    local -a RANK_QUOTA_OK=()
    local -a RANK_AMI_OK=()

    local _i
    for _i in "${!SCORE_REGIONS[@]}"; do
        local _r="${SCORE_REGIONS[$_i]}"
        local _az="${SCORE_AZS[$_i]}"
        local _raw="${SCORE_VALS[$_i]}"

        # Base score: spot placement score (0-10), N/A → 0
        local _score
        if [[ "$_raw" == "N/A" ]]; then
            _score=0
        else
            _score="$_raw"
        fi

        # Region-level penalties
        local _quota_ok="yes"
        local _ami_ok="yes"

        # Penalty: -3 if quota headroom < target capacity
        local _qs="${QUOTA_STATUS[$_r]:-unknown}"
        if [[ "$_qs" == "low" ]]; then
            _score=$((_score - 3))
            _quota_ok="no"
        elif [[ "$_qs" == "unknown" ]]; then
            local _qh="${QUOTA_HEADROOM[$_r]:-0}"
            if (( _qh < TARGET_CAPACITY )); then
                _score=$((_score - 3))
                _quota_ok="no"
            fi
        fi

        # Penalty: -2 if AMI does not exist in the region
        local _ae="${AMI_EXISTS[$_r]:-no}"
        if [[ "$_ae" != "yes" ]]; then
            _score=$((_score - 2))
            _ami_ok="no"
        fi

        RANK_REGIONS+=("$_r")
        RANK_AZS+=("$_az")
        RANK_COMPOSITE+=("$_score")
        RANK_SPOT_SCORE+=("$_raw")
        RANK_QUOTA_OK+=("$_quota_ok")
        RANK_AMI_OK+=("$_ami_ok")
    done

    # Sort: composite score descending, tiebreak: source-region first,
    # then alphabetical region, then alphabetical AZ.
    local _sort_file
    _sort_file=$(_make_temp)

    for _i in "${!RANK_REGIONS[@]}"; do
        local _cs="${RANK_COMPOSITE[$_i]}"
        # Pad score to 3 digits for sort stability (allows negative)
        local _padded
        _padded=$(printf '%+04d' "$_cs")

        # Tiebreaker key: source-region gets "0", others get "1"
        local _tiebreak
        if [[ "${RANK_REGIONS[$_i]}" == "$SOURCE_REGION" ]]; then
            _tiebreak="0"
        else
            _tiebreak="1"
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$_padded" "$_tiebreak" "${RANK_REGIONS[$_i]}" "${RANK_AZS[$_i]}" \
            "${RANK_COMPOSITE[$_i]}" "${RANK_SPOT_SCORE[$_i]}" \
            "${RANK_QUOTA_OK[$_i]}" "${RANK_AMI_OK[$_i]}" "$_i" \
            >> "$_sort_file"
    done

    # Sort descending by padded score, then ascending by tiebreak, region, AZ
    local _sorted_file
    _sorted_file=$(_make_temp)
    sort -t$'\t' -k1,1rn -k2,2n -k3,3 -k4,4 "$_sort_file" > "$_sorted_file"

    # Parse sorted results
    local -a FINAL_RANK=()
    local -a FINAL_REGION=()
    local -a FINAL_AZ=()
    local -a FINAL_SCORE=()
    local -a FINAL_SPOT=()
    local -a FINAL_QUOTA_OK=()
    local -a FINAL_AMI_OK=()

    local _rank=1
    local _padded _tiebreak _fr _faz _fcs _fspot _fqok _faok _orig_idx
    while IFS=$'\t' read -r _padded _tiebreak _fr _faz _fcs _fspot _fqok _faok _orig_idx; do
        FINAL_RANK+=("$_rank")
        FINAL_REGION+=("$_fr")
        FINAL_AZ+=("$_faz")
        FINAL_SCORE+=("$_fcs")
        FINAL_SPOT+=("$_fspot")
        FINAL_QUOTA_OK+=("$_fqok")
        FINAL_AMI_OK+=("$_faok")
        _rank=$((_rank + 1))
    done < "$_sorted_file"

    # ── Step 4: Recommended instance pool ─────────────────────────────────────
    # From the top-ranked region, list instance types that are:
    #   - offered in at least one AZ
    #   - have a spot price > $0.00
    local -a RECOMMENDED_POOL=()

    if (( ${#FINAL_REGION[@]} > 0 )); then
        local _top_region="${FINAL_REGION[0]}"

        local _type
        for _type in "${ALL_TYPES[@]}"; do
            local _okey="${_top_region}:${_type}"
            # Check offered
            if [[ "${TYPE_OFFERED_IN_REGION[$_okey]:-no}" != "yes" ]]; then
                continue
            fi

            # Check spot price > $0.00
            local _pkey="${_top_region}:${_type}"
            local _min_price="${PRICING_MIN[$_pkey]:-N/A}"
            if [[ "$_min_price" == "N/A" ]]; then
                continue
            fi
            # Compare to 0 using awk
            if awk "BEGIN { exit !($_min_price > 0) }"; then
                RECOMMENDED_POOL+=("$_type")
            fi
        done
    fi

    # ── Step 5: Recommend next action ─────────────────────────────────────────
    local NEXT_ACTION=""
    if (( ${#FINAL_REGION[@]} == 0 )); then
        NEXT_ACTION="No data available. Check AWS credentials and region selection."
    elif (( ${#RECOMMENDED_POOL[@]} == 0 )); then
        # Check if there are ANY offered types at all
        local _any_offered=0
        local _oregion _otype
        for _oregion in "${REGIONS[@]}"; do
            for _otype in "${ALL_TYPES[@]}"; do
                if [[ "${TYPE_OFFERED_IN_REGION[${_oregion}:${_otype}]:-no}" == "yes" ]]; then
                    _any_offered=1
                    break 2
                fi
            done
        done
        if (( !_any_offered )); then
            NEXT_ACTION="No GPU instance types offered in any candidate region. Check family selection."
        else
            NEXT_ACTION="No region has strong Spot capacity. Consider On-Demand mode or retry later."
        fi
    else
        local _top_score="${FINAL_SCORE[0]}"
        local _top_quota_ok="${FINAL_QUOTA_OK[0]}"
        local _top_ami_ok="${FINAL_AMI_OK[0]}"
        local _top_region="${FINAL_REGION[0]}"

        if (( _top_score >= 8 )) && [[ "$_top_ami_ok" == "yes" ]] && [[ "$_top_quota_ok" == "yes" ]]; then
            NEXT_ACTION="Start Portal infrastructure in ${_top_region} and run prepare_portal_region"
        elif (( _top_score >= 5 )) && [[ "$_top_ami_ok" != "yes" ]]; then
            NEXT_ACTION="Copy AMI to ${_top_region}, then start Portal infrastructure"
        elif (( _top_score >= 5 )) && [[ "$_top_quota_ok" != "yes" ]]; then
            NEXT_ACTION="Request quota increase for ${_FAMILIES[*]} in ${_top_region} before proceeding"
        else
            NEXT_ACTION="No region has strong Spot capacity. Consider On-Demand mode or retry later."
        fi
    fi

    # ── Step 6: Output ────────────────────────────────────────────────────────
    if (( JSON_OUTPUT )); then
        _output_json
    else
        _output_human
    fi

    # ── Step 7: GitLab workflow (optional) ────────────────────────────────────
    if [[ -n "$WORKFLOW_ISSUE" ]]; then
        _update_workflow_issue
    fi
}

# ── JSON output ───────────────────────────────────────────────────────────────
_output_json() {
    local _timestamp
    _timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # ranked_regions array
    local _ranked_json="[]"
    local _i
    for _i in "${!FINAL_RANK[@]}"; do
        local _spot_val="${FINAL_SPOT[$_i]}"
        [[ "$_spot_val" == "N/A" ]] && _spot_val="null"
        local _qok="true"
        [[ "${FINAL_QUOTA_OK[$_i]}" != "yes" ]] && _qok="false"
        local _aok="true"
        [[ "${FINAL_AMI_OK[$_i]}" != "yes" ]] && _aok="false"
        _ranked_json=$(echo "$_ranked_json" | jq \
            --arg rank "${FINAL_RANK[$_i]}" \
            --arg region "${FINAL_REGION[$_i]}" \
            --arg az "${FINAL_AZ[$_i]}" \
            --arg composite "${FINAL_SCORE[$_i]}" \
            --argjson spot "${_spot_val}" \
            --argjson quota_ok "$_qok" \
            --argjson ami_ok "$_aok" \
            '. + [{
                rank: ($rank | tonumber),
                region: $region,
                az: $az,
                composite_score: ($composite | tonumber),
                spot_score: $spot,
                quota_ok: $quota_ok,
                ami_ok: $ami_ok
            }]')
    done

    # recommended_pool array
    local _pool_json
    if (( ${#RECOMMENDED_POOL[@]} > 0 )); then
        _pool_json=$(printf '%s\n' "${RECOMMENDED_POOL[@]}" | jq -R . | jq -s .)
    else
        _pool_json="[]"
    fi

    # pricing object
    local _pricing_json="{}"
    local _region
    for _region in "${REGIONS[@]}"; do
        local _region_pricing="{}"
        local _type
        for _type in "${ALL_TYPES[@]}"; do
            local _pkey="${_region}:${_type}"
            local _pmin="${PRICING_MIN[$_pkey]:-N/A}"
            local _pmax="${PRICING_MAX[$_pkey]:-N/A}"
            local _pavg="${PRICING_AVG[$_pkey]:-N/A}"
            if [[ "$_pmin" != "N/A" ]]; then
                _region_pricing=$(echo "$_region_pricing" | jq \
                    --arg type "$_type" \
                    --arg min "$_pmin" \
                    --arg max "$_pmax" \
                    --arg avg "$_pavg" \
                    '. + {($type): {min: $min, max: $max, avg: $avg}}')
            fi
        done
        _pricing_json=$(echo "$_pricing_json" | jq \
            --arg region "$_region" \
            --argjson rp "$_region_pricing" \
            '. + {($region): $rp}')
    done

    # ami_status object
    local _ami_json="{}"
    for _region in "${REGIONS[@]}"; do
        local _ae="${AMI_EXISTS[$_region]:-no}"
        local _aid="${AMI_ID_MAP[$_region]:-}"
        if [[ "$_ae" == "yes" ]]; then
            _ami_json=$(echo "$_ami_json" | jq \
                --arg region "$_region" \
                --arg ami_id "$_aid" \
                '. + {($region): {exists: true, ami_id: $ami_id}}')
        else
            _ami_json=$(echo "$_ami_json" | jq \
                --arg region "$_region" \
                '. + {($region): {exists: false}}')
        fi
    done

    # quota_warnings array
    local _quota_warnings_json="[]"
    for _region in "${REGIONS[@]}"; do
        local _qs="${QUOTA_STATUS[$_region]:-unknown}"
        if [[ "$_qs" == "low" ]]; then
            local _qh="${QUOTA_HEADROOM[$_region]:-0}"
            _quota_warnings_json=$(echo "$_quota_warnings_json" | jq \
                --arg region "$_region" \
                --arg headroom "$_qh" \
                --arg target "$TARGET_CAPACITY" \
                '. + ["Quota low in \($region): headroom=\($headroom), target=\($target)"]')
        fi
    done

    # args object
    local _regions_arr _families_arr _types_arr
    _regions_arr=$(printf '%s\n' "${REGIONS[@]}" | jq -R . | jq -s .)
    _families_arr=$(printf '%s\n' "${_FAMILIES[@]}" | jq -R . | jq -s .)
    _types_arr=$(printf '%s\n' "${ALL_TYPES[@]}" | jq -R . | jq -s .)

    # Assemble final JSON
    jq -n \
        --arg timestamp "$_timestamp" \
        --argjson regions "$_regions_arr" \
        --argjson families "$_families_arr" \
        --argjson types "$_types_arr" \
        --argjson target_cap "$TARGET_CAPACITY" \
        --argjson ranked "$_ranked_json" \
        --argjson pool "$_pool_json" \
        --argjson pricing "$_pricing_json" \
        --argjson ami_status "$_ami_json" \
        --argjson quota_warnings "$_quota_warnings_json" \
        --arg next_action "$NEXT_ACTION" \
        '{
            timestamp: $timestamp,
            args: {
                regions: $regions,
                families: $families,
                instance_types: $types,
                target_capacity: $target_cap
            },
            ranked_regions: $ranked,
            recommended_pool: $pool,
            pricing: $pricing,
            ami_status: $ami_status,
            quota_warnings: $quota_warnings,
            next_action: $next_action
        }'
}

# ── Human-readable output ─────────────────────────────────────────────────────
_output_human() {
    echo ""
    echo "=== GPU Capacity Scan Results ==="
    echo ""

    # Ranked table
    printf "%-4s  %-11s %-15s %-5s  %-8s %-6s\n" \
        "RANK" "REGION" "AZ" "SCORE" "QUOTA_OK" "AMI_OK"
    printf "%-4s  %-11s %-15s %-5s  %-8s %-6s\n" \
        "----" "-----------" "---------------" "-----" "--------" "------"

    local _i
    for _i in "${!FINAL_RANK[@]}"; do
        printf "%-4s  %-11s %-15s %-5s  %-8s %-6s\n" \
            "${FINAL_RANK[$_i]}" \
            "${FINAL_REGION[$_i]}" \
            "${FINAL_AZ[$_i]}" \
            "${FINAL_SCORE[$_i]}" \
            "${FINAL_QUOTA_OK[$_i]}" \
            "${FINAL_AMI_OK[$_i]}"
    done

    echo ""

    # Recommended pool
    echo "--- Recommended Instance Pool (top region) ---"
    if (( ${#RECOMMENDED_POOL[@]} > 0 )); then
        local _i
        for _i in "${!RECOMMENDED_POOL[@]}"; do
            local _type="${RECOMMENDED_POOL[$_i]}"
            local _top_region="${FINAL_REGION[0]}"
            local _pkey="${_top_region}:${_type}"
            local _pmin="${PRICING_MIN[$_pkey]:-N/A}"
            local _pmax="${PRICING_MAX[$_pkey]:-N/A}"
            local _pavg="${PRICING_AVG[$_pkey]:-N/A}"
            printf "  %-15s  spot: \$%s–\$%s (avg \$%s)\n" \
                "$_type" "$_pmin" "$_pmax" "$_pavg"
        done
    else
        echo "  (no recommended types)"
    fi
    echo ""

    # Price summary per region
    echo "--- Spot Pricing Summary ---"
    local _region
    for _region in "${REGIONS[@]}"; do
        echo "  $_region:"
        local _type
        for _type in "${ALL_TYPES[@]}"; do
            local _pkey="${_region}:${_type}"
            local _pmin="${PRICING_MIN[$_pkey]:-N/A}"
            local _pmax="${PRICING_MAX[$_pkey]:-N/A}"
            local _pavg="${PRICING_AVG[$_pkey]:-N/A}"
            printf "    %-15s  \$%s / \$%s / \$%s\n" "$_type" "$_pmin" "$_pmax" "$_pavg"
        done
    done
    echo ""

    # AMI status
    echo "--- AMI Status ---"
    for _region in "${REGIONS[@]}"; do
        local _ae="${AMI_EXISTS[$_region]:-no}"
        local _aid="${AMI_ID_MAP[$_region]:-}"
        if [[ "$_ae" == "yes" ]]; then
            echo "  $_region: exists ($_aid)"
        else
            echo "  $_region: needs_copy_from:$SOURCE_REGION"
        fi
    done
    echo ""

    # Quota warnings
    echo "--- Quota Status ---"
    for _region in "${REGIONS[@]}"; do
        local _qs="${QUOTA_STATUS[$_region]:-unknown}"
        local _qh="${QUOTA_HEADROOM[$_region]:-0}"
        if [[ "$_qs" == "ok" ]]; then
            echo "  $_region: headroom $_qh, status ok"
        elif [[ "$_qs" == "low" ]]; then
            echo "  $_region: headroom $_qh, status LOW (target: $TARGET_CAPACITY)"
        else
            echo "  $_region: headroom $_qh, status unknown"
        fi
    done
    echo ""

    # Next action
    echo "=== Next Action ==="
    echo "  $NEXT_ACTION"
    echo ""
}

# ── GitLab workflow update ────────────────────────────────────────────────────
_update_workflow_issue() {
    echo "Updating workflow issue #${WORKFLOW_ISSUE}..." >&2

    # Build the JSON output for state_write
    local _json_output
    _json_output=$(jq -n \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg next_action "$NEXT_ACTION" \
        --arg top_region "${FINAL_REGION[0]:-none}" \
        --arg top_score "${FINAL_SCORE[0]:-0}" \
        '{scan_timestamp: $timestamp, next_action: $next_action, top_region: $top_region, top_score: ($top_score | tonumber)}')

    # 1. state_write
    state_write "$WORKFLOW_ISSUE" "$_json_output" || {
        echo "WARNING: state_write failed for issue #${WORKFLOW_ISSUE}" >&2
    }

    # 2. fsm_transition to SCANNED
    fsm_transition "$WORKFLOW_ISSUE" "SCANNED" || {
        echo "WARNING: fsm_transition failed for issue #${WORKFLOW_ISSUE}" >&2
    }

    # 3. Build inventory markdown
    local _top_region="${FINAL_REGION[0]:-N/A}"
    local _top_score="${FINAL_SCORE[0]:-0}"
    local _pool_str
    if (( ${#RECOMMENDED_POOL[@]} > 0 )); then
        _pool_str=$(IFS=','; echo "${RECOMMENDED_POOL[*]}")
    else
        _pool_str="none"
    fi

    local _ami_status_str
    if [[ "${AMI_EXISTS[$_top_region]:-no}" == "yes" ]]; then
        _ami_status_str="exists"
    else
        _ami_status_str="needs_copy_from:${SOURCE_REGION}"
    fi

    local _qh="${QUOTA_HEADROOM[$_top_region]:-0}"
    local _qs="${QUOTA_STATUS[$_top_region]:-unknown}"

    # Compute overall pricing range from recommended pool in top region
    local _pmin_overall="N/A"
    local _pmax_overall="N/A"
    local _pavg_overall="N/A"
    if (( ${#RECOMMENDED_POOL[@]} > 0 )); then
        local _rtype
        for _rtype in "${RECOMMENDED_POOL[@]}"; do
            local _rpkey="${_top_region}:${_rtype}"
            local _rmin="${PRICING_MIN[$_rpkey]:-N/A}"
            local _rmax="${PRICING_MAX[$_rpkey]:-N/A}"
            local _ravg="${PRICING_AVG[$_rpkey]:-N/A}"
            if [[ "$_rmin" != "N/A" ]]; then
                if [[ "$_pmin_overall" == "N/A" ]] || awk "BEGIN { exit !($_rmin < $_pmin_overall) }"; then
                    _pmin_overall="$_rmin"
                fi
            fi
            if [[ "$_rmax" != "N/A" ]]; then
                if [[ "$_pmax_overall" == "N/A" ]] || awk "BEGIN { exit !($_rmax > $_pmax_overall) }"; then
                    _pmax_overall="$_rmax"
                fi
            fi
            if [[ "$_ravg" != "N/A" ]]; then
                _pavg_overall="$_ravg"
            fi
        done
    fi

    local _inventory_md
    _inventory_md="## Resource Inventory
- **Top region:** ${_top_region} (score ${_top_score})
- **Recommended pool:** ${_pool_str}
- **AMI status:** ${_ami_status_str}
- **Quota:** headroom ${_qh}, status ${_qs}
- **Spot pricing:** \$${_pmin_overall}–\$${_pmax_overall} (avg \$${_pavg_overall})"

    issue_update_inventory "$WORKFLOW_ISSUE" "$_inventory_md" || {
        echo "WARNING: issue_update_inventory failed for issue #${WORKFLOW_ISSUE}" >&2
    }

    # 4. issue_update_next_action
    issue_update_next_action "$WORKFLOW_ISSUE" "$NEXT_ACTION" || {
        echo "WARNING: issue_update_next_action failed for issue #${WORKFLOW_ISSUE}" >&2
    }

    # 5. issue_log
    issue_log "$WORKFLOW_ISSUE" "Capacity scan completed" || {
        echo "WARNING: issue_log failed for issue #${WORKFLOW_ISSUE}" >&2
    }

    echo "Workflow issue #${WORKFLOW_ISSUE} updated." >&2
}

# ── Entry point ───────────────────────────────────────────────────────────────
main "$@"

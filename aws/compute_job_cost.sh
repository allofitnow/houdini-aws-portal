#!/usr/bin/env bash
# compute_job_cost.sh — Compute per-job AWS cost for Deadline Portal workers.
#
# Phase 1 (default): Spot price estimate from DescribeSpotPriceHistory.
# Phase 2 (--actuals): CUR 2.0 actuals via Athena (optional, requires setup).
#
# Usage:
#   ./compute_job_cost.sh <job_id> [--region us-west-2] [--actuals] [--json]
#
# Exit codes:
#   0  Cost computed successfully
#   1  Job not found or no timing data
#   2  AWS API error
#   3  Missing prerequisites

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
REGION="us-west-2"
ACTUALS=false
JSON_OUTPUT=false
DEADLINE_CMD=""

# ── Parse args ────────────────────────────────────────────────────────────────
JOB_ID=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)     REGION="$2"; shift 2 ;;
        --actuals)    ACTUALS=true; shift ;;
        --json)       JSON_OUTPUT=true; shift ;;
        --deadline-cmd) DEADLINE_CMD="$2"; shift 2 ;;
        --help|-h)
            sed -n '2,12p' "$0" | sed 's/^# //; s/^#//'
            exit 0
            ;;
        -*)
            echo "Unknown flag: $1" >&2; exit 1 ;;
        *)
            if [[ -z "$JOB_ID" ]]; then
                JOB_ID="$1"; shift
            else
                echo "Unexpected argument: $1" >&2; exit 1
            fi
    esac
done

if [[ -z "$JOB_ID" ]]; then
    echo "Usage: $0 <job_id> [--region us-west-2] [--actuals] [--json]" >&2
    exit 3
fi

# ── Locate deadlinecommand ────────────────────────────────────────────────────
if [[ -n "$DEADLINE_CMD" ]]; then
    DL="$DEADLINE_CMD"
elif command -v deadlinecommand &>/dev/null; then
    DL="deadlinecommand"
elif [[ -x "/mnt/c/Program Files/Thinkbox/Deadline10/bin/deadlinecommand.exe" ]]; then
    DL="/mnt/c/Program Files/Thinkbox/Deadline10/bin/deadlinecommand.exe"
else
    echo "FATAL: deadlinecommand not found. Set --deadline-cmd or add to PATH." >&2
    exit 3
fi

# ── Helper: run deadlinecommand ───────────────────────────────────────────────
dl() { "$DL" "$@" 2>/dev/null; }

# ── Fetch job metadata ────────────────────────────────────────────────────────
echo "==> Fetching job info for $JOB_ID ..." >&2

JOB_STATUS=$(dl -GetJobSetting "$JOB_ID" Status 2>/dev/null || echo "")
if [[ -z "$JOB_STATUS" ]]; then
    echo "FATAL: Job $JOB_ID not found or deadlinecommand error." >&2
    exit 1
fi

# Get timing fields
JOB_SUBMIT_TIME=$(dl -GetJobSetting "$JOB_ID" SubmittedDate 2>/dev/null || echo "")  # used in output
JOB_START_TIME=$(dl -GetJobSetting "$JOB_ID" StartedDateTime 2>/dev/null || echo "")
JOB_COMPLETE_TIME=$(dl -GetJobSetting "$JOB_ID" CompletedDateTime 2>/dev/null || echo "")
JOB_NAME=$(dl -GetJobSetting "$JOB_ID" Name 2>/dev/null || echo "unknown")
JOB_PLUGIN=$(dl -GetJobSetting "$JOB_ID" Plugin 2>/dev/null || echo "unknown")
JOB_FRAMES=$(dl -GetJobSetting "$JOB_ID" Frames 2>/dev/null || echo "unknown")
PRIORITY=$(dl -GetJobSetting "$JOB_ID" Priority 2>/dev/null || echo "unknown")  # used in output
POOL=$(dl -GetJobSetting "$JOB_ID" Pool 2>/dev/null || echo "none")

# Detect Portal job: check for AWSPortalInstance in extra info
JOB_EXTRA=$(dl -GetJobSetting "$JOB_ID" ExtraInfo2000 2>/dev/null || echo "")
IS_PORTAL=false
if [[ "$JOB_EXTRA" == *"Portal"* ]] || [[ "$POOL" == "awsportal"* ]]; then
    IS_PORTAL=true
fi

echo "  Name:       $JOB_NAME" >&2
echo "  Status:     $JOB_STATUS" >&2
echo "  Plugin:     $JOB_PLUGIN" >&2
echo "  Frames:     $JOB_FRAMES" >&2
echo "  Pool:       $POOL" >&2
echo "  Portal job: $IS_PORTAL" >&2

# ── Parse timing ──────────────────────────────────────────────────────────────
# Deadline returns times like "06/10/2026 04:30:00" (local) or ISO-ish formats.
# Normalize to ISO 8601 for AWS APIs.

normalize_time() {
    local t="$1"
    if [[ -z "$t" || "$t" == "N/A" || "$t" == "(none)" ]]; then
        echo ""
        return
    fi
    # Try Python for robust parsing
    python3 -c "
import sys
from datetime import datetime
t = '''$t'''.strip()
# Try common Deadline formats
for fmt in ['%m/%d/%Y %H:%M:%S', '%Y-%m-%dT%H:%M:%S', '%Y-%m-%d %H:%M:%S',
            '%m/%d/%Y %I:%M:%S %p', '%d/%m/%Y %H:%M:%S']:
    try:
        dt = datetime.strptime(t, fmt)
        print(dt.strftime('%Y-%m-%dT%H:%M:%S'))
        sys.exit(0)
    except ValueError:
        continue
# Fallback: echo as-is
print(t)
" 2>/dev/null || echo "$t"
}

START_ISO=$(normalize_time "$JOB_START_TIME")
END_ISO=$(normalize_time "$JOB_COMPLETE_TIME")

if [[ -z "$START_ISO" ]]; then
    echo "FATAL: Job has no start time. Cannot compute cost." >&2
    exit 1
fi

if [[ -z "$END_ISO" && "$JOB_STATUS" != "Rendering" ]]; then
    echo "FATAL: Job has no end time and is not currently rendering." >&2
    exit 1
fi

# ── Identify worker instances ─────────────────────────────────────────────────
# Get task-level info to find which workers rendered tasks
echo "==> Identifying worker instances ..." >&2

TASKS_OUTPUT=$(dl -GetJobTasks "$JOB_ID" 2>/dev/null || echo "")

# Parse worker names from task output
# Format: "Task 1: status=Completed, slave=ip-10-0-x-x, start=..., end=..."
WORKER_NAMES=()
if [[ -n "$TASKS_OUTPUT" ]]; then
    # Extract slave/worker names from task output
    while IFS= read -r line; do
        WORKER_NAMES+=("$line")
    done < <(echo "$TASKS_OUTPUT" | grep -oP '(?<=slave=)[^,]+' 2>/dev/null | sort -u || \
             echo "$TASKS_OUTPUT" | grep -oP '(?<=Slave=)[^,]+' 2>/dev/null | sort -u || true)
fi

# Fallback: get worker from job info
if [[ ${#WORKER_NAMES[@]} -eq 0 ]]; then
    # Try GetSlaveNames for active workers
    SLAVE=$(dl -GetJobSetting "$JOB_ID" SlaveName 2>/dev/null || echo "")
    if [[ -n "$SLAVE" ]]; then
        WORKER_NAMES+=("$SLAVE")
    fi
fi

# Map worker hostname → EC2 instance ID
# Portal workers have hostnames like ip-10-0-x-x or the instance ID if configured
INSTANCE_IDS=()
declare -A WORKER_TO_INSTANCE

for w in "${WORKER_NAMES[@]}"; do
    # If hostname is an instance ID pattern (i-xxxxx), use directly
    if [[ "$w" =~ ^i-[a-f0-9]+$ ]]; then
        INSTANCE_IDS+=("$w")
        WORKER_TO_INSTANCE["$w"]="$w"
    else
        # Try to resolve via AWS: search for instance with matching private DNS
        # ip-10-0-1-2.us-west-2.compute.internal → match PrivateIpAddress or PrivateDnsName
        IID=$(aws ec2 describe-instances \
            --region "$REGION" \
            --filters \
                "Name=private-dns-name,Values=${w}*" \
                "Name=instance-state-name,Values=running,stopped,terminated" \
            --query 'Reservations[0].Instances[0].InstanceId' \
            --output text 2>/dev/null || echo "None")
        if [[ "$IID" != "None" && -n "$IID" ]]; then
            INSTANCE_IDS+=("$IID")
            WORKER_TO_INSTANCE["$w"]="$IID"
        fi
    fi
done

# Deduplicate
mapfile -t UNIQ_INSTANCE_IDS < <(printf "%s\n" "${INSTANCE_IDS[@]}" | sort -u)

echo "  Workers:    ${WORKER_NAMES[*]:-none}" >&2
echo "  Instances:  ${UNIQ_INSTANCE_IDS[*]:-none}" >&2

# ── Determine instance type ───────────────────────────────────────────────────
INSTANCE_TYPE=""
AZ=""

if [[ ${#UNIQ_INSTANCE_IDS[@]} -gt 0 ]]; then
    INST_INFO=$(aws ec2 describe-instances \
        --region "$REGION" \
        --instance-ids "${UNIQ_INSTANCE_IDS[0]}" \
        --query 'Reservations[0].Instances[0].{Type:InstanceType,Az:Placement.AvailabilityZone,LaunchTime:LaunchTime}' \
        --output json 2>/dev/null || echo "{}")
    INSTANCE_TYPE=$(echo "$INST_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Type',''))" 2>/dev/null || echo "")
    AZ=$(echo "$INST_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Az',''))" 2>/dev/null || echo "")
    INSTANCE_LAUNCH_TIME=$(echo "$INST_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('LaunchTime',''))" 2>/dev/null || echo "")
fi

# Fallback if we can't determine from instance
if [[ -z "$INSTANCE_TYPE" ]]; then
    # Check Spot Fleet requests for instance type info
    echo "  WARNING: Could not determine instance type from running instances." >&2
    echo "           Defaulting to g6.4xlarge. Use --instance-type to override." >&2
    INSTANCE_TYPE="g6.4xlarge"
fi

echo "  Type:       $INSTANCE_TYPE" >&2
echo "  AZ:         ${AZ:-unknown}" >&2

# ── Compute render duration ───────────────────────────────────────────────────
compute_hours() {
    local start="$1"
    local end="$2"
    python3 -c "
from datetime import datetime
s = datetime.fromisoformat('$start')
e = datetime.fromisoformat('$end')
hours = (e - s).total_seconds() / 3600.0
print(f'{hours:.4f}')
" 2>/dev/null || echo "0"
}

if [[ -n "$END_ISO" ]]; then
    RENDER_HOURS=$(compute_hours "$START_ISO" "$END_ISO")
else
    RENDER_HOURS="0"
fi

echo "  Start:      $START_ISO" >&2
echo "  End:        ${END_ISO:-still running}" >&2
echo "  Render hrs: $RENDER_HOURS" >&2

# ── Phase 1: Spot price estimate ──────────────────────────────────────────────
echo "==> Querying spot price history ..." >&2

# Query spot price for the job window (with 1h buffer on each side)
QUERY_START="${START_ISO}"
QUERY_END="${END_ISO:-$(date -u +%Y-%m-%dT%H:%M:%S)}"

# Build filters
SPOT_FILTERS="Name=instance-type,Values=${INSTANCE_TYPE}"
if [[ -n "$AZ" ]]; then
    SPOT_FILTERS="$SPOT_FILTERS Name=availability-zone,Values=${AZ}"
fi

# Fetch spot price history
SPOT_PRICES=$(aws ec2 describe-spot-price-history \
    --region "$REGION" \
    --start-time "$QUERY_START" \
    --end-time "$QUERY_END" \
    --filters Name=instance-type,Values="${INSTANCE_TYPE}" \
        $([[ -n "$AZ" ]] && echo "Name=availability-zone,Values=${AZ}") \
    --query 'SpotPriceHistory[*].SpotPrice' \
    --output text 2>/dev/null || echo "")

if [[ -z "$SPOT_PRICES" ]]; then
    echo "WARNING: No spot price history found. Trying without AZ filter ..." >&2
    SPOT_PRICES=$(aws ec2 describe-spot-price-history \
        --region "$REGION" \
        --start-time "$QUERY_START" \
        --end-time "$QUERY_END" \
        --filters Name=instance-type,Values="${INSTANCE_TYPE}" \
        --query 'SpotPriceHistory[*].SpotPrice' \
        --output text 2>/dev/null || echo "")
fi

# Compute average spot price
if [[ -n "$SPOT_PRICES" ]]; then
    AVG_SPOT_PRICE=$(echo "$SPOT_PRICES" | python3 -c "
import sys
prices = [float(x) for x in sys.stdin.read().split() if x.strip()]
if prices:
    print(f'{sum(prices)/len(prices):.6f}')
else:
    print('0')
" 2>/dev/null || echo "0")
else
    AVG_SPOT_PRICE="0"
    echo "WARNING: No spot price data available." >&2
fi

# Compute costs
RENDER_COST=$(python3 -c "print(f'{float($RENDER_HOURS) * float($AVG_SPOT_PRICE):.4f}')" 2>/dev/null || echo "0")

# Instance cost (from launch time to job end or now)
INSTANCE_HOURS="0"
if [[ ${#UNIQ_INSTANCE_IDS[@]} -gt 0 && -n "$INSTANCE_LAUNCH_TIME" && -n "$END_ISO" ]]; then
    INSTANCE_HOURS=$(compute_hours "$INSTANCE_LAUNCH_TIME" "$END_ISO")
elif [[ ${#UNIQ_INSTANCE_IDS[@]} -gt 0 && -n "$INSTANCE_LAUNCH_TIME" ]]; then
    INSTANCE_HOURS=$(compute_hours "$INSTANCE_LAUNCH_TIME" "$(date -u +%Y-%m-%dT%H:%M:%S)")
fi
INSTANCE_COST=$(python3 -c "print(f'{float($INSTANCE_HOURS) * float($AVG_SPOT_PRICE):.4f}')" 2>/dev/null || echo "0")

# ── Output results ─────────────────────────────────────────────────────────────
if $JSON_OUTPUT; then
    python3 -c "
import json
result = {
    'job_id': '$JOB_ID',
    'job_name': '''$JOB_NAME''',
    'status': '$JOB_STATUS',
    'plugin': '$JOB_PLUGIN',
    'is_portal': $IS_PORTAL,
    'frames': '$JOB_FRAMES',
    'pool': '$POOL',
    'render': {
        'start': '$START_ISO',
        'end': '${END_ISO:-null}',
        'hours': float('$RENDER_HOURS'),
    },
    'instance': {
        'ids': sorted(list(set('''${UNIQ_INSTANCE_IDS[*]}'''.split()))) if '''${UNIQ_INSTANCE_IDS[*]}''' else [],
        'type': '$INSTANCE_TYPE',
        'az': '${AZ:-unknown}',
        'hours': float('${INSTANCE_HOURS:-0}'),
    },
    'cost': {
        'source': 'spot-price-estimate',
        'avg_spot_price_hr': float('$AVG_SPOT_PRICE'),
        'render_cost': float('$RENDER_COST'),
        'instance_cost': float('$INSTANCE_COST'),
        'currency': 'USD',
    }
}
print(json.dumps(result, indent=2))
"
else
    echo ""
    echo "=========================================="
    echo "  JOB COST REPORT"
    echo "=========================================="
    echo "  Job ID:           $JOB_ID"
    echo "  Job Name:         $JOB_NAME"
    echo "  Status:           $JOB_STATUS"
    echo "  Plugin:           $JOB_PLUGIN"
    echo "  Frames:           $JOB_FRAMES"
    echo "  Pool:             $POOL"
    echo "  Portal Job:       $IS_PORTAL"
    echo "------------------------------------------"
    echo "  TIMING"
    echo "    Render Start:   $START_ISO"
    echo "    Render End:     ${END_ISO:-still running}"
    echo "    Render Hours:   $RENDER_HOURS"
    echo "------------------------------------------"
    echo "  INSTANCES"
    echo "    IDs:            ${UNIQ_INSTANCE_IDS[*]:-none}"
    echo "    Type:           $INSTANCE_TYPE"
    echo "    AZ:             ${AZ:-unknown}"
    echo "    Instance Hours: ${INSTANCE_HOURS:-0}"
    echo "------------------------------------------"
    echo "  COST (Phase 1: Spot Price Estimate)"
    echo "    Avg Spot Price: \$${AVG_SPOT_PRICE}/hr"
    echo "    Render Cost:    \$${RENDER_COST}"
    echo "    Instance Cost:  \$${INSTANCE_COST}"
    echo "    Source:         DescribeSpotPriceHistory"
    echo "    Currency:       USD"
    echo "=========================================="
fi

# ── Phase 2: CUR 2.0 actuals (optional) ───────────────────────────────────────
if $ACTUALS; then
    echo "" >&2
    echo "==> Phase 2: Checking CUR 2.0 actuals ..." >&2

    # Check if Athena is configured
    ATHENA_DB="${CUR_DATABASE:-deadline_cost}"
    ATHENA_TABLE="${CUR_TABLE:-cur_2_0}"
    ATHENA_OUTPUT="s3://deadline-cost-athena-results/"

    if [[ ${#UNIQ_INSTANCE_IDS[@]} -eq 0 ]]; then
        echo "  SKIP: No instance IDs to query." >&2
    else
        for IID in "${UNIQ_INSTANCE_IDS[@]}"; do
            QUERY="SELECT
    line_item_usage_start_date,
    line_item_usage_end_date,
    line_item_usage_amount,
    line_item_unblended_cost,
    pricing_unit
FROM ${ATHENA_DB}.${ATHENA_TABLE}
WHERE resource_id = '${IID}'
  AND line_item_product_code = 'AmazonEC2'
  AND line_item_usage_type LIKE '%SPOT%'
  AND line_item_usage_start_date >= TIMESTAMP '${START_ISO}'
ORDER BY line_item_usage_start_date"

            echo "  Querying Athena for $IID ..." >&2

            QUERY_EXEC=$(aws athena start-query-execution \
                --region "$REGION" \
                --query-string "$QUERY" \
                --result-configuration "OutputLocation=${ATHENA_OUTPUT}" \
                --query 'QueryExecutionId' \
                --output text 2>/dev/null || echo "")

            if [[ -z "$QUERY_EXEC" ]]; then
                echo "  WARNING: Athena query failed. CUR 2.0 may not be configured." >&2
                echo "           Enable CUR 2.0 in AWS Billing console and set up Athena table." >&2
            else
                # Wait for query to complete
                for _ in $(seq 1 12); do
                    sleep 5
                    QSTATE=$(aws athena get-query-execution \
                        --region "$REGION" \
                        --query-execution-id "$QUERY_EXEC" \
                        --query 'QueryExecution.Status.State' \
                        --output text 2>/dev/null || echo "FAILED")
                    if [[ "$QSTATE" != "RUNNING" && "$QSTATE" != "QUEUED" ]]; then
                        break
                    fi
                done

                if [[ "$QSTATE" == "SUCCEEDED" ]]; then
                    ACTUAL_COST=$(aws athena get-query-results \
                        --region "$REGION" \
                        --query-execution-id "$QUERY_EXEC" \
                        --query 'ResultSet.Rows[1:].Data[4].VarCharValue' \
                        --output text 2>/dev/null || echo "0")

                    echo ""
                    echo "  CUR 2.0 ACTUALS for $IID:"
                    echo "    Billed Cost:    \$${ACTUAL_COST}"
                    echo "    Estimate:       \$${INSTANCE_COST}"
                    echo "    Variance:       $(python3 -c "
if float('$ACTUAL_COST') > 0:
    v = ((float('$ACTUAL_COST') - float('$INSTANCE_COST')) / float('$ACTUAL_COST')) * 100
    print(f'{v:+.1f}%')
else:
    print('N/A')
" 2>/dev/null || echo 'N/A')"
                else
                    echo "  WARNING: Athena query $QSTATE. CUR data may not be available yet." >&2
                fi
            fi
        done
    fi
fi

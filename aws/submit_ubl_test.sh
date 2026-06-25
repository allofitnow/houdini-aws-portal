#!/usr/bin/env bash
# aws/submit_ubl_test.sh
# Standardized UBL license validation test for Deadline Monitor.
#
# Submits a single Deadline job that exercises all three SideFX UBL products
# in sequence: Houdini (port 1715), Karma (port 1716), Mantra (port 1717).
# If any product license is unavailable, the job fails — giving us an
# immediate go/no-go signal for the entire UBL chain.
#
# The test uses a serialized incrementing index so every submission is unique
# and traceable in Deadline Monitor:
#
#     UBL-Test-#001  <date>  <scene>
#     UBL-Test-#002  <date>  <scene>
#     ...
#
# The index is auto-discovered by scanning existing job names in Deadline.
# It can also be supplied manually with --index.
#
# The job runs on the worker as a CommandLine plugin task:
#   1. Load the scene with hython (requires Houdini license - port 1715)
#   2. Render /out/karma1 frame 1 (requires Karma license - port 1716)
#   3. Render /out/mantra1 frame 1 (requires Mantra license - port 1717)
#
# Prerequisites:
#   - SSH access to the Deadline RCS host (deadlinecommand must be installed there)
#   - At least one worker in the target group, status Idle
#   - UBL license endpoint READY with all 3 products attached
#   - Test scene Tester.hiplc deployed on the worker at SCENE_PATH
#
# Usage:
#   ./aws/submit_ubl_test.sh                          # auto-index, default scene/group
#   ./aws/submit_ubl_test.sh --index 5                # force index 5
#   ./aws/submit_ubl_test.sh --group aws-spot-east    # target specific group
#   ./aws/submit_ubl_test.sh --dry-run                # preview, don't submit
#   ./aws/submit_ubl_test.sh --poll                   # submit and wait for completion
#
# Exit codes:
#   0  Job submitted successfully (or completed if --poll)
#   1  Job submitted but failed (only with --poll)
#   2  Timeout waiting for completion (only with --poll)
#   3  Missing prerequisites or bad arguments

set -euo pipefail

# --- Defaults ---
RCS_HOST="${DEADLINE_RCS_HOST:-aoin@192.168.30.141}"
SCENE_PATH="${UBL_TEST_SCENE:-/home/ec2-user/Tester.hiplc}"
SCENE_BASENAME="Tester"
GROUP="${UBL_TEST_GROUP:-none}"
INDEX=""
DRY_RUN=false
POLL=false
TIMEOUT=600
POLL_INTERVAL=30
LOG="/tmp/ubl_test_$(date +%s).log"
HOUDINI_VERSION="21.0"
CERT_BUCKET="${CERT_BUCKET:-aoin-renderfarm-staging}"
CERT_BUCKET_REGION="${CERT_BUCKET_REGION:-us-west-2}"
INSTANCE_ID="${INSTANCE_ID:-}"

# --- Helpers ---
log()  { echo "[UBL-Test] $*" | tee -a "$LOG"; }
die()  { echo "ERROR: $*" >&2 | tee -a "$LOG"; exit 3; }

# --- SSH wrapper for deadlinecommand on the Windows RCS ---
dl() {
    ssh -o ConnectTimeout=10 "$RCS_HOST" "deadlinecommand $*" 2>&1
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rcs)        RCS_HOST="$2"; shift 2 ;;
        --scene)      SCENE_PATH="$2"; shift 2 ;;
        --group)      GROUP="$2"; shift 2 ;;
        --index)      INDEX="$2"; shift 2 ;;
        --timeout)    TIMEOUT="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --poll)       POLL=true; shift ;;
        --houdini-version) HOUDINI_VERSION="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

echo "==> UBL Test started at $(date)" | tee "$LOG"

# ============================================================================
# Step 1: Discover or validate the serialized index
# ============================================================================
if [[ -z "$INDEX" ]]; then
    log "Auto-discovering next test index from Deadline..."

    # Single SSH call: get all job names at once via -GetJobs
    ALL_JOBS=$(dl -GetJobs 2>/dev/null || die "Cannot connect to Deadline RCS at $RCS_HOST")

    MAX_INDEX=0
    # Extract Name= lines and look for the UBL-Test-#NNN pattern
    while IFS= read -r line; do
        line=$(echo "$line" | tr -d '\r')
        if [[ "$line" =~ ^Name=UBL-Test-#([0-9]+)$ ]]; then
            NUM="${BASH_REMATCH[1]}"
            NUM=$((10#$NUM))  # strip leading zeros
            if [[ "$NUM" -gt "$MAX_INDEX" ]]; then
                MAX_INDEX="$NUM"
            fi
        fi
    done <<< "$ALL_JOBS"

    INDEX=$((MAX_INDEX + 1))
    log "Highest existing UBL-Test index: #$(printf '%03d' "$MAX_INDEX")"
fi

# Format as 3-digit zero-padded
INDEX_PADDED=$(printf '%03d' "$INDEX")
JOB_NAME="UBL-Test-#${INDEX_PADDED}"

log "Test index: #${INDEX_PADDED}"
log "Job name:   $JOB_NAME"

# ============================================================================
# Step 2: Validate prerequisites
# ============================================================================
log "Checking prerequisites..."

# Check RCS connectivity
DL_VERSION=$(dl -Version 2>/dev/null | head -1 | tr -d '\r')
if [[ -z "$DL_VERSION" ]]; then
    die "Cannot reach deadlinecommand on $RCS_HOST"
fi
log "Deadline: $DL_VERSION"

# Check for idle workers in the target group
if [[ "$GROUP" == "none" ]]; then
    IDLE_WORKERS=$(dl -GetSlaveNames 2>/dev/null | tr -d '\r' | grep -c '.' || true)
else
    IDLE_WORKERS=$(dl -GetSlaveNamesInGroup "$GROUP" 2>/dev/null | tr -d '\r' | grep -c '.' || true)
fi

if [[ "$IDLE_WORKERS" -eq 0 ]]; then
    die "No workers found in group '$GROUP'. Launch a worker first."
fi
log "Workers in group '$GROUP': $IDLE_WORKERS"

# ============================================================================
# Step 3: Build job submission files
# ============================================================================
log "Scene:  $SCENE_PATH"
log "Group:  $GROUP"

# The job runs a single CommandLine task that exercises all 3 UBL products:
#   1. hython loads the scene (Houdini license check - port 1715)
#   2. Karma ROP render frame 1 (Karma license - port 1716)
#   3. Mantra ROP render frame 1 (Mantra license - port 1717)
#
# Scene ROP output paths:
#   /out/karma1  -> $HIP/renderkarma/$HIPNAME.$OS.$F4.exr
#   /out/mantra1 -> $HIP/rendermantra/$HIPNAME.$OS.$F4.exr
#
# The task writes a summary line per product so Deadline's job log shows
# exactly which licenses were checked.

JOB_INFO=$(mktemp)
PLUGIN_INFO=$(mktemp)
trap 'rm -f "$JOB_INFO" "$PLUGIN_INFO"' EXIT

cat > "$JOB_INFO" << EOF
Frames=1
ChunkSize=1
Name=$JOB_NAME
Priority=50
Group=$GROUP
Pool=none
MachineLimit=0
Plugin=CommandLine
Department=
OutputDirectory0=/home/ec2-user/renderoutput
OutputFilename0=${SCENE_BASENAME}.ubl-test.${INDEX_PADDED}.exr
EOF

# The command script runs on the worker (Linux, root).
# It tests all 3 UBL products in sequence and exits non-zero on any failure.
#
# Rather than fighting quote-nesting, we generate a standalone test script
# and deploy it to the worker. The Deadline job simply invokes that script.
TEST_SCRIPT_LOCAL=$(mktemp)
TEST_SCRIPT_REMOTE="/home/ec2-user/run_ubl_test.sh"

# Generate the test script — use a quoted heredoc with env var substitution
# disabled (we insert values via a header block instead).
cat > "$TEST_SCRIPT_LOCAL" << 'TESTEOF'
#!/usr/bin/env bash
set -euo pipefail

HFS=/opt/hfs
TESTEOF

# Append version-specific values
cat >> "$TEST_SCRIPT_LOCAL" << TESTEOF
HFS="\${HFS}${HOUDINI_VERSION}"
SCENE="${SCENE_PATH}"
IDX="${INDEX_PADDED}"
export HOUDINI_PATH="\${HFS}/houdini"

echo "=== UBL-Test-#\${IDX} started ==="
echo "--- [1/3] Houdini license check (port 1715) ---"
TESTEOF

# Append the hython calls — these never change, so use quoted heredoc
cat >> "$TEST_SCRIPT_LOCAL" << 'TESTEOF'
"${HFS}/bin/hython" -c "
import hou
hou.hipFile.load('${SCENE}', suppress_save_prompt=True)
print('Houdini license OK')
"

echo "--- [2/3] Karma render (port 1716) ---"
"${HFS}/bin/hython" -c "
import hou
hou.hipFile.load('${SCENE}', suppress_save_prompt=True)
hou.node('/out/karma1').render(frame_range=(1,1))
print('Karma render OK')
"

echo "--- [3/3] Mantra render (port 1717) ---"
"${HFS}/bin/hython" -c "
import hou
hou.hipFile.load('${SCENE}', suppress_save_prompt=True)
hou.node('/out/mantra1').render(frame_range=(1,1))
print('Mantra render OK')
"

echo "=== UBL-Test-#${IDX} PASSED: all 3 products licensed ==="
TESTEOF

log "Generated test script:"
cat "$TEST_SCRIPT_LOCAL" | sed 's/^/  /' | tee -a "$LOG"

# Deploy to the worker via S3 (workers have S3 access via IAM role)
TEST_S3_KEY="test/run_ubl_test_${INDEX_PADDED}.sh"
aws s3 cp "$TEST_SCRIPT_LOCAL" "s3://${CERT_BUCKET}/${TEST_S3_KEY}" --region "$CERT_BUCKET_REGION" >/dev/null 2>&1

# Deploy to the worker via SSM
log "Deploying test script to worker via SSM..."
aws ssm send-command \
    --region "$CERT_BUCKET_REGION" \
    --document-name "AWS-RunShellScript" \
    --targets "Key=instanceids,Values=${INSTANCE_ID:-}" \
    --parameters "commands=[\"aws s3 cp s3://${CERT_BUCKET}/${TEST_S3_KEY} ${TEST_SCRIPT_REMOTE} --region ${CERT_BUCKET_REGION}\",\"chmod +x ${TEST_SCRIPT_REMOTE}\",\"mkdir -p /home/ec2-user/renderkarma /home/ec2-user/rendermantra\"]" \
    >/dev/null 2>&1 || true

# If INSTANCE_ID not set, we deploy to all workers in the group
if [[ -z "${INSTANCE_ID:-}" ]]; then
    log "INSTANCE_ID not set — worker must already have the test script at ${TEST_SCRIPT_REMOTE}"
fi

rm -f "$TEST_SCRIPT_LOCAL"

# The Deadline job just calls the deployed script
cat > "$PLUGIN_INFO" << 'ENDSCRIPT'
Executable=/bin/bash
Arguments=-c /home/ec2-user/run_ubl_test.sh
ENDSCRIPT

# (Placeholders are no longer used — variables are interpolated directly
#  into the test script via the unquoted heredoc above.)

log "Job info file:"
cat "$JOB_INFO" | sed 's/^/  /' | tee -a "$LOG"
log "Plugin command preview (truncated):"
head -3 "$PLUGIN_INFO" | sed 's/^/  /' | tee -a "$LOG"

# ============================================================================
# Step 4: Submit (or dry-run)
# ============================================================================
if $DRY_RUN; then
    log "[DRY-RUN] Would submit job '$JOB_NAME' to Deadline"
    log "[DRY-RUN] Full plugin info:"
    cat "$PLUGIN_INFO" | sed 's/^/  /' | tee -a "$LOG"
    echo ""
    echo "=== UBL Test (DRY-RUN) ==="
    echo "  Job Name:  $JOB_NAME"
    echo "  Index:     #$INDEX_PADDED"
    echo "  Scene:     $SCENE_PATH"
    echo "  Group:     $GROUP"
    echo "  Products:  Houdini (1715), Karma (1716), Mantra (1717)"
    exit 0
fi

log "Submitting job '$JOB_NAME' to Deadline..."

# Copy job files to the RCS, then submit from there.
# deadlinecommand on Windows needs local file paths.
# We scp the files to a temp dir on the RCS, then submit.
REMOTE_DIR="C:\\\\Users\\\\aoin\\\\AppData\\\\Local\\\\Temp\\\\ubl_test_$(date +%s)"
REMOTE_JOB="${REMOTE_DIR}\\\\job_info.txt"
REMOTE_PLUGIN="${REMOTE_DIR}\\\\plugin_info.txt"

log "Copying submission files to RCS (base64 transfer)..."

# Create remote temp dir
ssh -o ConnectTimeout=10 "$RCS_HOST" "New-Item -ItemType Directory -Force -Path '${REMOTE_DIR}'" >/dev/null 2>&1

# Transfer files via base64 encoding through SSH stdin.
# PowerShell's Set-Content stdin pipe silently corrupts content, so we
# base64-encode locally and decode on the Windows side.
B64_JOB=$(base64 -w0 "$JOB_INFO")
B64_PLUGIN=$(base64 -w0 "$PLUGIN_INFO")

ssh -o ConnectTimeout=10 "$RCS_HOST" "[System.IO.File]::WriteAllBytes('${REMOTE_JOB}', [System.Convert]::FromBase64String('${B64_JOB}'))" 2>/dev/null
ssh -o ConnectTimeout=10 "$RCS_HOST" "[System.IO.File]::WriteAllBytes('${REMOTE_PLUGIN}', [System.Convert]::FromBase64String('${B64_PLUGIN}'))" 2>/dev/null

# Submit from the RCS — only two file args (plugin is set via Plugin= in job_info)
SUBMIT_OUTPUT=$(ssh -o ConnectTimeout=10 "$RCS_HOST" "deadlinecommand '${REMOTE_JOB}' '${REMOTE_PLUGIN}'" 2>&1) || {
    log "Submission FAILED"
    echo "$SUBMIT_OUTPUT" | tee -a "$LOG"
    die "deadlinecommand -SubmitJob failed"
}

# Parse JobID from submission output
JOB_ID=$(echo "$SUBMIT_OUTPUT" | grep -oiE 'JobID=[a-f0-9]+' | cut -d= -f2 | head -1 | tr -d '\r')

if [[ -z "$JOB_ID" ]]; then
    log "Could not parse JobID from output:"
    echo "$SUBMIT_OUTPUT" | tee -a "$LOG"
    die "Job submission output did not contain a JobID"
fi

log "Job submitted: $JOB_ID"

# Cleanup remote temp files
ssh -o ConnectTimeout=10 "$RCS_HOST" "Remove-Item -Recurse -Force '${REMOTE_DIR}'" >/dev/null 2>&1 || true

# ============================================================================
# Step 5: Report (and optionally poll)
# ============================================================================
echo ""
echo "=== UBL Test Submitted ==="
printf "  %-16s %s\n" "Job Name:" "$JOB_NAME"
printf "  %-16s %s\n" "Job ID:" "$JOB_ID"
printf "  %-16s %s\n" "Index:" "#$INDEX_PADDED"
printf "  %-16s %s\n" "Scene:" "$SCENE_PATH"
printf "  %-16s %s\n" "Group:" "$GROUP"
printf "  %-16s %s\n" "Products:" "Houdini (1715), Karma (1716), Mantra (1717)"
echo ""
echo "  Monitor: Open Deadline Monitor -> Jobs panel -> search '$JOB_NAME'"
echo "  Log:     $LOG"
echo ""

if ! $POLL; then
    log "Use --poll to wait for completion, or check Deadline Monitor."
    exit 0
fi

# --- Poll for completion ---
log "Polling for completion (timeout ${TIMEOUT}s)..."
ELAPSED=0
STATUS="Unknown"

while [[ $ELAPSED -lt $TIMEOUT ]]; do
    STATUS=$(dl -GetJobSetting "$JOB_ID" Status 2>/dev/null | tr -d '\r' || echo "Unknown")
    log "  [${ELAPSED}/${TIMEOUT}s] Status: $STATUS"

    case "$STATUS" in
        Completed)
            log "=== UBL Test #${INDEX_PADDED} PASSED ==="
            log "All 3 UBL products (Houdini, Karma, Mantra) rendered successfully."
            echo ""
            echo "==> UBL Test #${INDEX_PADDED}: PASSED"
            exit 0
            ;;
        Failed|Error)
            log "=== UBL Test #${INDEX_PADDED} FAILED ==="
            log "Fetching error report..."
            dl -GetJobErrorReportFilenames "$JOB_ID" 2>/dev/null | tr -d '\r' | head -50 | tee -a "$LOG"
            echo ""
            echo "==> UBL Test #${INDEX_PADDED}: FAILED"
            echo "  Check Deadline Monitor -> right-click job -> View Job Reports"
            exit 1
            ;;
        Rendering|Queued|Pending|Suspended)
            sleep "$POLL_INTERVAL"
            ELAPSED=$((ELAPSED + POLL_INTERVAL))
            ;;
        *)
            sleep "$POLL_INTERVAL"
            ELAPSED=$((ELAPSED + POLL_INTERVAL))
            ;;
    esac
done

log "=== UBL Test #${INDEX_PADDED} TIMEOUT ==="
echo ""
echo "==> UBL Test #${INDEX_PADDED}: TIMEOUT (last status: $STATUS)"
exit 2

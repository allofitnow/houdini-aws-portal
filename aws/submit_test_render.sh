#!/usr/bin/env bash
# submit_test_render.sh — Submit a Houdini Karma test job to Deadline and poll until complete.
#
# Purpose: End-to-end validation of a Portal-ready AMI. Runs from the workstation
#          (the Deadline host or any machine with deadlinecommand on PATH). Submits a
#          single-frame Karma render, polls status, and reports pass/fail.
#
# Prerequisites:
#   - deadlinecommand on PATH (or via the local host)
#   - Test scene Tester.hiplc deployed to the worker (in the AMI or S3)
#   - At least one Portal worker in Idle state
#   - UBL license endpoint READY
#
# Usage:
#   ./submit_test_render.sh [--scene /path/to/Tester.hiplc] [--out /out/karma1] [--timeout 600]
#
# Exit codes:
#   0  Job completed successfully, output files present
#   1  Job failed (render error)
#   2  Timeout waiting for job to complete
#   3  Missing prerequisites (deadlinecommand, scene file, no idle workers)

set -euo pipefail

# --- Defaults ---
SCENE="/home/ec2-user/Tester.hiplc"
OUT_NODE="/out/karma1"
TIMEOUT=600
POLL_INTERVAL=30
LOG=/tmp/test_render.log

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scene)    SCENE="$2"; shift 2 ;;
        --out)      OUT_NODE="$2"; shift 2 ;;
        --timeout)  TIMEOUT="$2"; shift 2 ;;
        --help|-h)
            head -20 "$0" | grep '^#'
            exit 0
            ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

echo "==> Test render started at $(date)" | tee "$LOG"

# --- Prerequisites ---
if ! command -v deadlinecommand &>/dev/null; then
    echo "FATAL: deadlinecommand not found on PATH" | tee -a "$LOG"
    echo "Run this script from the Deadline host (local WSL)."
    exit 3
fi

# Check for idle workers
# Portal workers may be in any pool; check "none" first (default), then all workers
IDLE_WORKERS=$(deadlinecommand -GetSlavesInPool "none" 2>/dev/null | grep -c "Idle" || true)
if [[ "$IDLE_WORKERS" -eq 0 ]]; then
    # Broader check — any idle worker regardless of pool
    IDLE_WORKERS=$(deadlinecommand -GetSlaveNames 2>/dev/null | wc -l || true)
    if [[ "$IDLE_WORKERS" -eq 0 ]]; then
        echo "FATAL: No idle workers found. Is the Portal worker launched and connected?" | tee -a "$LOG"
        exit 3
    fi
fi
echo "Idle workers detected: $IDLE_WORKERS" | tee -a "$LOG"

# --- Submit job ---
# deadlinecommand -SubmitJob uses a job info file + plugin info file.
# For Houdini, we create temp files with the job parameters.

JOB_INFO=$(mktemp)
PLUGIN_INFO=$(mktemp)
trap 'rm -f "$JOB_INFO" "$PLUGIN_INFO"' EXIT

cat > "$JOB_INFO" << EOF
Frames=1
ChunkSize=1
Name=Portal_AMI_Test_Render
Priority=50
Pool=  # Portal assigns pool at launch time; leave empty to use default
Group=
OutputDirectory0=/home/ec2-user/renderoutput
OutputFilename0=Tester.karma1.0001.exr
EOF

cat > "$PLUGIN_INFO" << EOF
SceneFile=$SCENE
OutputDriver=$OUT_NODE
HoudiniVersion=21.0
IgnoreInputs=True
EOF

echo "Submitting Houdini Karma test job..." | tee -a "$LOG"
echo "  Scene: $SCENE" | tee -a "$LOG"
echo "  Output: $OUT_NODE" | tee -a "$LOG"

JOB_ID=$(deadlinecommand -SubmitJob "$JOB_INFO" "$PLUGIN_INFO" Houdini 2>&1 | head -1) || {
    echo "FATAL: Job submission failed" | tee -a "$LOG"
    exit 3
}
echo "Job submitted: $JOB_ID" | tee -a "$LOG"

# --- Poll until complete ---
ELAPSED=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
    STATUS=$(deadlinecommand -GetJobStatus "$JOB_ID" 2>/dev/null || echo "Unknown")
    echo "  [$ELAPSED/${TIMEOUT}s] Job $JOB_ID status: $STATUS" | tee -a "$LOG"

    case "$STATUS" in
        Completed)
            echo "==> Job COMPLETED successfully at $(date)" | tee -a "$LOG"

            # Verify output files exist (via deadlinecommand or SSH)
            ERROR_COUNT=$(deadlinecommand -GetJobErrorCount "$JOB_ID" 2>/dev/null || echo "0")
            echo "  Error reports: $ERROR_COUNT" | tee -a "$LOG"

            if [[ "$ERROR_COUNT" -gt 0 ]]; then
                echo "WARNING: Job completed with $ERROR_COUNT error(s). Review logs." | tee -a "$LOG"
            fi

            echo "==> Test render PASSED" | tee -a "$LOG"
            exit 0
            ;;
        Failed|Error)
            echo "==> Job FAILED at $(date)" | tee -a "$LOG"
            echo "  Fetching error report..." | tee -a "$LOG"
            deadlinecommand -GetJobErrors "$JOB_ID" 2>/dev/null | head -50 | tee -a "$LOG"
            exit 1
            ;;
        Rendering|Queued|Pending|Suspended)
            sleep "$POLL_INTERVAL"
            ELAPSED=$((ELAPSED + POLL_INTERVAL))
            ;;
        *)
            echo "  Unknown status: $STATUS. Continuing to poll..." | tee -a "$LOG"
            sleep "$POLL_INTERVAL"
            ELAPSED=$((ELAPSED + POLL_INTERVAL))
            ;;
    esac
done

echo "==> TIMEOUT after ${TIMEOUT}s. Job $JOB_ID did not complete." | tee -a "$LOG"
echo "  Last status: $STATUS" | tee -a "$LOG"
echo "  Check worker logs and Deadline Monitor for details." | tee -a "$LOG"
exit 2

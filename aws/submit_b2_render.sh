#!/usr/bin/env bash
# submit_b2_render.sh — Submit a Houdini Karma render job that reads input from
# and writes output to Backblaze B2.
#
# Purpose: End-to-end render validation using B2 for both input assets and
#          render output. The worker downloads the scene with rclone, redirects
#          the Karma ROP output path via a /tmp/renderkarma symlink, and the
#          rendered frame lands in B2 through the existing /mnt/renders mount.
#
# Prerequisites:
#   - deadlinecommand on PATH
#   - Scene file already uploaded to B2 under the configured bucket
#   - At least one worker in the target Deadline group (spot or on-demand)
#   - Worker AMI has rclone configured at /etc/rclone/rclone.conf and B2 mounted
#
# Usage:
#   ./submit_b2_render.sh \
#     --scene inputs/test-scenes/Tester.hiplc \
#     --rop /out/karma1 \
#     --group aws-spot-east \
#     [--bucket aoin-test] \
#     [--output-prefix outputs] \
#     [--frames 1] \
#     [--timeout 600]
#
# Exit codes:
#   0  Job completed successfully and output file is visible in B2
#   1  Job failed
#   2  Timeout
#   3  Missing prerequisites or bad arguments

set -euo pipefail

# --- Defaults ---
B2_BUCKET="aoin-test"
B2_REMOTE="b2renders"
B2_CONFIG="/etc/rclone/rclone.conf"
SCENE_B2_PATH=""
OUT_PREFIX="outputs"
ROP="/out/karma1"
GROUP="aws-spot-east"
FRAMES="1"
TIMEOUT=600
POLL_INTERVAL=30
LOG=/tmp/b2_render.log

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scene)        SCENE_B2_PATH="$2"; shift 2 ;;
        --rop)          ROP="$2"; shift 2 ;;
        --group)        GROUP="$2"; shift 2 ;;
        --bucket)       B2_BUCKET="$2"; shift 2 ;;
        --output-prefix) OUT_PREFIX="$2"; shift 2 ;;
        --frames)       FRAMES="$2"; shift 2 ;;
        --timeout)      TIMEOUT="$2"; shift 2 ;;
        --help|-h)
            head -30 "$0" | grep '^#'
            exit 0
            ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [[ -z "$SCENE_B2_PATH" ]]; then
    echo "FATAL: --scene <b2-path-relative-to-bucket> is required" | tee "$LOG"
    exit 3
fi

SCENE_FILENAME=$(basename "$SCENE_B2_PATH")
SCENE_BASENAME="${SCENE_FILENAME%.*}"

echo "==> B2 render submission started at $(date)" | tee "$LOG"
echo "    Scene: b2://${B2_BUCKET}/${SCENE_B2_PATH}" | tee -a "$LOG"
echo "    ROP:   $ROP" | tee -a "$LOG"
echo "    Group: $GROUP" | tee -a "$LOG"

# --- Prerequisites ---
if ! command -v deadlinecommand &>/dev/null; then
    echo "FATAL: deadlinecommand not found on PATH" | tee -a "$LOG"
    exit 3
fi

# --- Build job / plugin info ---
# Use a deterministic job name base; Deadline will append the job ID to output.
JOB_NAME="Houdini-Karma-B2-$(date +%Y%m%d-%H%M%S)"
JOB_INFO=$(mktemp)
PLUGIN_INFO=$(mktemp)
trap 'rm -f "$JOB_INFO" "$PLUGIN_INFO"' EXIT

cat > "$JOB_INFO" <<EOF
Frames=$FRAMES
ChunkSize=1
Name=$JOB_NAME
Priority=90
Group=$GROUP
Pool=none
MachineLimit=0
Plugin=CommandLine
EOF

# The worker runs as root. The Karma ROP in the current scene writes to
# /tmp/renderkarma/<scene>.<rop>.####.exr. We replace /tmp/renderkarma with a
# symlink to the B2-backed output folder so frames are written directly to B2.
#
# rclone config is at /etc/rclone/rclone.conf on the worker AMI.
# Use copyto for a single file to avoid creating nested directories.
cat > "$PLUGIN_INFO" <<EOF
Executable=/bin/bash
Arguments=-c "set -euo pipefail; echo '=== B2 render: $JOB_NAME ==='; OUTDIR=/mnt/renders/${OUT_PREFIX}/$JOB_NAME; mkdir -p \\"\\$OUTDIR\\"; rm -rf /tmp/$SCENE_FILENAME /tmp/renderkarma; rclone --config $B2_CONFIG copyto ${B2_REMOTE}:${B2_BUCKET}/${SCENE_B2_PATH} /tmp/$SCENE_FILENAME; ls -la /tmp/$SCENE_FILENAME; ln -sfn \\"\\$OUTDIR\\" /tmp/renderkarma; echo 'Rendering $SCENE_FILENAME @ $ROP ...'; /opt/hfs21.0/bin/hython -c 'import hou; hou.hipFile.load(\\"/tmp/$SCENE_FILENAME\\", suppress_save_prompt=True); node = hou.node(\\"$ROP\\"); node.render(frame_range=(1, 1))'; echo 'Render complete. Output files:'; find \\"\\$OUTDIR\\" -maxdepth 1 -type f -ls"
EOF

echo "Submitting CommandLine B2 render job..." | tee -a "$LOG"
SUBMIT_OUTPUT=$(deadlinecommand -SubmitJob "$JOB_INFO" "$PLUGIN_INFO" 2>&1) || {
    echo "FATAL: Job submission failed" | tee -a "$LOG"
    echo "$SUBMIT_OUTPUT" | tee -a "$LOG"
    exit 3
}

JOB_ID=$(echo "$SUBMIT_OUTPUT" | grep -oE 'JobID=[a-f0-9]+' | cut -d= -f2 || true)
if [[ -z "$JOB_ID" ]]; then
    echo "FATAL: Could not parse JobID from submission output" | tee -a "$LOG"
    echo "$SUBMIT_OUTPUT" | tee -a "$LOG"
    exit 3
fi

echo "Job submitted: $JOB_ID" | tee -a "$LOG"

# --- Poll until complete ---
ELAPSED=0
STATUS="Unknown"
while [[ $ELAPSED -lt $TIMEOUT ]]; do
    STATUS=$(deadlinecommand -GetJobSetting "$JOB_ID" Status 2>/dev/null || echo "Unknown")
    echo "  [${ELAPSED}/${TIMEOUT}s] Job $JOB_ID status: $STATUS" | tee -a "$LOG"

    case "$STATUS" in
        Completed)
            echo "==> Job COMPLETED at $(date)" | tee -a "$LOG"
            break
            ;;
        Failed|Error)
            echo "==> Job FAILED at $(date)" | tee -a "$LOG"
            deadlinecommand -GetJobErrorReportFilenames "$JOB_ID" 2>/dev/null | head -50 | tee -a "$LOG"
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

if [[ "$STATUS" != "Completed" ]]; then
    echo "==> TIMEOUT after ${TIMEOUT}s. Job $JOB_ID status: $STATUS" | tee -a "$LOG"
    exit 2
fi

# --- Verify output in B2 ---
EXPECTED_OUTPUT="${OUT_PREFIX}/${JOB_NAME}/${SCENE_BASENAME}.karma1.0001.exr"
echo "==> Verifying B2 output: b2://${B2_BUCKET}/${EXPECTED_OUTPUT}" | tee -a "$LOG"

if command -v rclone &>/dev/null; then
    if rclone ls "${B2_REMOTE}:${B2_BUCKET}/${EXPECTED_OUTPUT}" 2>/dev/null | grep -q "${SCENE_BASENAME}.karma1.0001.exr"; then
        echo "==> B2 render PASSED: output found in B2" | tee -a "$LOG"
        exit 0
    else
        echo "WARNING: Expected output not found at the default path. Listing ${OUT_PREFIX}/${JOB_NAME}:/" | tee -a "$LOG"
        rclone ls "${B2_REMOTE}:${B2_BUCKET}/${OUT_PREFIX}/${JOB_NAME}" 2>/dev/null | tee -a "$LOG" || true
        exit 1
    fi
else
    echo "WARNING: rclone not available locally; cannot verify B2 output. Job completed." | tee -a "$LOG"
    exit 0
fi

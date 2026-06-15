#!/usr/bin/env bash
# s3_upload_frame.sh
# Post-task script for Deadline. Uploads the rendered frame to S3.
# This is executed by the Deadline Worker immediately after a task finishes.

set -euo pipefail

# These are provided by Deadline's event plugin or post-task arguments.
# For simplicity, we expect the renderer to output to /tmp/renders/
# and Deadline passes the output path as an argument.
# Usage: s3_upload_frame.sh <JOB_NAME> <RENDER_OUTPUT_FILE>

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <JOB_NAME> <RENDER_OUTPUT_FILE>"
    exit 1
fi

JOB_NAME="$1"
OUTPUT_FILE="$2"
# Note: In a real post-task script, we'd use Deadline's Python API to get
# the exact S3_BUCKET. Here we hardcode or fetch from instance metadata.
S3_BUCKET="aoin-deadline-render-output-774538489810"

if [[ ! -f "$OUTPUT_FILE" ]]; then
    echo "ERROR: Output file $OUTPUT_FILE not found."
    exit 1
fi

FILENAME=$(basename "$OUTPUT_FILE")
S3_KEY="renders/${JOB_NAME}/${FILENAME}"

echo "Uploading $OUTPUT_FILE to s3://${S3_BUCKET}/${S3_KEY}..."

# Retry loop for resilience
MAX_RETRIES=3
RETRY_COUNT=0

while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    if aws s3 cp "$OUTPUT_FILE" "s3://${S3_BUCKET}/${S3_KEY}" --quiet; then
        echo "Successfully uploaded ${FILENAME} to S3."
        # Clean up local file to save disk space
        rm -f "$OUTPUT_FILE"
        exit 0
    else
        echo "Upload failed. Retrying in 5 seconds..."
        sleep 5
        ((RETRY_COUNT++))
    fi
done

echo "ERROR: Failed to upload $OUTPUT_FILE after $MAX_RETRIES attempts."
exit 1

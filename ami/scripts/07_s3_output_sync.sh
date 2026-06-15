#!/usr/bin/env bash
# 07_s3_output_sync.sh
# Installs the S3 post-task upload script into the AMI.

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1
set -euo pipefail

echo "==> [07] S3 Output Sync setup started at $(date)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="/usr/local/bin/s3_upload_frame.sh"

if [[ -f "$SCRIPT_DIR/s3_upload_frame.sh" ]]; then
    cp "$SCRIPT_DIR/s3_upload_frame.sh" "$TARGET"
    chmod +x "$TARGET"
    echo "==> [07] Installed $TARGET"
else
    echo "FATAL: s3_upload_frame.sh not found in $SCRIPT_DIR"
    exit 1
fi

# Ensure output directory exists with generous permissions for the worker
mkdir -p /tmp/renders
chmod 777 /tmp/renders

echo "==> [07] S3 Output Sync setup complete"

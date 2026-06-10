#!/usr/bin/env bash
# ami/build.sh
# Orchestrates the full AMI build by running scripts 01-06 in order.
# Targets Amazon Linux 2023 with Deadline Portal (no ZeroTier, no B2).
# Run as root on the temporary GPU build instance in the selected AWS region.
#
# Precondition: scripts/ directory exists alongside this file with all
#   numbered steps present. The instance needs S3 read access and
#   Secrets Manager read access for the license endpoint secret.
#
# Usage:
#   sudo bash build.sh \
#     --s3-bucket <YOUR_S3_BUCKET> \
#     --houdini-build <BUILD_NUMBER> \
#     --aws-region <REGION> \
#     --license-endpoint-secret-id <SECRET_ID>
#
# Example:
#   sudo bash build.sh --s3-bucket deadline-houdini-installers \
#                      --houdini-build 506 \
#                      --aws-region us-west-2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts"
LOG=/var/log/ami-build.log

# Redirect all output to the shared build log
mkdir -p "$(dirname "$LOG")"
exec >> "$LOG" 2>&1

# Defaults
S3_BUCKET=""
HOUDINI_BUILD=""
AWS_REGION="${AWS_REGION:-us-west-2}"
HOUDINI_LICENSE_ENDPOINT_SECRET_ID="${HOUDINI_LICENSE_ENDPOINT_SECRET_ID:-houdini/license-endpoint-dns}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --s3-bucket)    S3_BUCKET="$2";         shift 2 ;;
        --houdini-build) HOUDINI_BUILD="$2";    shift 2 ;;
        --aws-region|--region) AWS_REGION="$2"; shift 2 ;;
        --license-endpoint-secret-id) HOUDINI_LICENSE_ENDPOINT_SECRET_ID="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; shift ;;
    esac
done

# Validate required args
MISSING=""
[[ -z "$S3_BUCKET" ]]        && MISSING="$MISSING --s3-bucket"
[[ -z "$HOUDINI_BUILD" ]]    && MISSING="$MISSING --houdini-build"
if [[ -n "$MISSING" ]]; then
    echo "ERROR: Missing required arguments:$MISSING"
    exit 1
fi

export S3_BUCKET HOUDINI_BUILD AWS_REGION HOUDINI_LICENSE_ENDPOINT_SECRET_ID

echo "==> AMI build started at $(date)"

run_step() {
    local script="$1"
    echo ""
    echo "======================================"
    echo "Running: $script"
    echo "======================================"
    bash "$SCRIPT_DIR/$script"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "FATAL: $script failed with exit code $rc"
        echo "Check $LOG for details"
        exit "$rc"
    fi
}

run_step 01_system_prep.sh

# Reboot gate: only needed once, to activate Nouveau blacklist.
# If nouveau is still loaded OR blacklist file doesn't exist yet, reboot.
# On second run, nouveau is gone and we proceed to step 02.
BLACKLIST_FILE="/etc/modprobe.d/blacklist-nouveau.conf"
if ! modprobe -n nouveau 2>/dev/null || [[ ! -f "$BLACKLIST_FILE" ]]; then
    echo ""
    echo "==> Nouveau blacklist active, proceeding to NVIDIA driver install..."
elif lsmod | grep -q nouveau; then
    echo ""
    echo "==> Rebooting to activate Nouveau blacklist before NVIDIA driver install..."
    echo "==> Re-run this script after reboot to continue from step 02."
    echo "==> (The script detects completion of step 01 via /var/log/ami-build.log)"
    echo ""
    echo "==> First run complete. Reboot and re-run build.sh to continue."
    exit 0
fi

run_step 02_nvidia_drivers.sh
run_step 04_houdini.sh

# Copy test scene to ec2-user home for validation renders
INSTALL_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$INSTALL_SRC/test/Tester.hiplc" ]]; then
    cp "$INSTALL_SRC/test/Tester.hiplc" /home/ec2-user/Tester.hiplc
    chown ec2-user:ec2-user /home/ec2-user/Tester.hiplc
    echo "==> Copied test/Tester.hiplc to /home/ec2-user/"
else
    echo "WARNING: test/Tester.hiplc not found at $INSTALL_SRC/test/ — skipping copy"
fi

run_step 05_deadline_worker.sh
run_step 06_cleanup.sh

echo ""
echo "==> AMI build complete at $(date)"
echo "==> Instance is ready to snapshot. Run from your workstation:"
echo "    ./aws/create_ami.sh <INSTANCE_ID> --region ${AWS_REGION}"

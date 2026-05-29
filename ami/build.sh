#!/usr/bin/env bash
# build.sh
# Orchestrates the full AMI build by running scripts 01-06 in order.
# Run as root on the temporary GPU build instance in the selected AWS region.
#
# Usage:
#   sudo bash build.sh \
#     --repo-ip <ZEROTIER_IP_OF_DEADLINE_REPO> \
#     --s3-bucket <YOUR_S3_BUCKET> \
#     --houdini-build <BUILD_NUMBER> \
#     --b2-bucket <YOUR_B2_BUCKET> \
#     --aws-region <REGION> \
#     --license-endpoint-secret-id <SECRET_ID>
#
# Example:
#   sudo bash build.sh --repo-ip 10.147.20.5 --s3-bucket renderfarm-installers \
#                      --houdini-build 506 --b2-bucket renders-allofitnow \
#                      --aws-region us-west-2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts"
LOG=/var/log/ami-build.log

# Defaults
DEADLINE_REPO_IP=""
S3_BUCKET=""
HOUDINI_BUILD=""
B2_BUCKET=""
AWS_REGION="${AWS_REGION:-us-west-2}"
HOUDINI_LICENSE_ENDPOINT_SECRET_ID="${HOUDINI_LICENSE_ENDPOINT_SECRET_ID:-houdini/license-endpoint-dns}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-ip)      DEADLINE_REPO_IP="$2"; shift 2 ;;
        --s3-bucket)    S3_BUCKET="$2";         shift 2 ;;
        --houdini-build) HOUDINI_BUILD="$2";    shift 2 ;;
        --b2-bucket)    B2_BUCKET="$2";          shift 2 ;;
        --aws-region|--region) AWS_REGION="$2"; shift 2 ;;
        --license-endpoint-secret-id) HOUDINI_LICENSE_ENDPOINT_SECRET_ID="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; shift ;;
    esac
done

# Validate required args
MISSING=""
[[ -z "$DEADLINE_REPO_IP" ]] && MISSING="$MISSING --repo-ip"
[[ -z "$S3_BUCKET" ]]        && MISSING="$MISSING --s3-bucket"
[[ -z "$HOUDINI_BUILD" ]]    && MISSING="$MISSING --houdini-build"
[[ -z "$B2_BUCKET" ]]        && MISSING="$MISSING --b2-bucket"
if [[ -n "$MISSING" ]]; then
    echo "ERROR: Missing required arguments:$MISSING"
    exit 1
fi

export DEADLINE_REPO_IP S3_BUCKET HOUDINI_BUILD B2_BUCKET AWS_REGION HOUDINI_LICENSE_ENDPOINT_SECRET_ID

mkdir -p "$(dirname "$LOG")"
echo "==> AMI build started at $(date)" | tee -a "$LOG"

run_step() {
    local script="$1"
    echo "" | tee -a "$LOG"
    echo "======================================" | tee -a "$LOG"
    echo "Running: $script" | tee -a "$LOG"
    echo "======================================" | tee -a "$LOG"
    bash "$SCRIPT_DIR/$script"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "FATAL: $script failed with exit code $rc" | tee -a "$LOG"
        echo "Check $LOG for details"
        exit $rc
    fi
}

run_step 01_system_prep.sh

echo ""
echo "==> Rebooting to activate Nouveau blacklist before NVIDIA driver install..."
echo "==> Re-run this script after reboot to continue from step 02."
echo "==> (The script detects completion of step 01 via /var/log/ami-build.log)"
echo ""

# If NVIDIA driver is already installed, skip the reboot gate
if dpkg -l | grep -q "^ii.*nvidia-driver"; then
    echo "==> NVIDIA driver already installed, continuing..."
else
    echo "==> First run complete. Reboot and re-run build.sh to continue."
    exit 0
fi

run_step 02_nvidia_drivers.sh
run_step 03_zerotier.sh

echo ""
echo "==> ACTION REQUIRED: Authorize the ZeroTier node shown above at:"
echo "    https://my.zerotier.com/network/d3ecf5726d14ac76"
echo "==> Press ENTER once the node is authorized to continue..."
read -r

run_step 04_houdini.sh
run_step 04b_rclone_b2.sh
run_step 05_deadline_worker.sh
run_step 06_cleanup.sh

echo ""
echo "==> AMI build complete at $(date)" | tee -a "$LOG"
echo "==> Instance is ready to snapshot. Run from your workstation:"
echo "    ./aws/create_ami.sh <INSTANCE_ID> --region ${AWS_REGION}"

#!/usr/bin/env bash
# Wrapper to run step 05 via SSM - writes the actual script to instance then executes
# This avoids quoting hell with SSM parameters

export S3_BUCKET="deadline-houdini-installers"
export DEADLINE_REPO_IP="10.147.18.89"
export AWS_REGION="us-west-2"
DEADLINE_VERSION="10.4.2.3"
DEADLINE_POOL="houdini-aws-gpu"
DEADLINE_GROUP="linux-gpu"
INSTALLER="DeadlineClient-${DEADLINE_VERSION}-linux-x64-installer.run"

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1
set -euo pipefail

echo "==> [05] Deadline Worker install started at $(date)"

TMP_DIR=$(mktemp -d)

echo "==> [05] Downloading ${INSTALLER} from S3..."
aws s3 cp "s3://${S3_BUCKET}/installers/${INSTALLER}" "${TMP_DIR}/${INSTALLER}" --region "$AWS_REGION"

chmod +x "${TMP_DIR}/${INSTALLER}"

echo "==> [05] Running Deadline Client installer..."
"${TMP_DIR}/${INSTALLER}" \
    --mode unattended \
    --prefix /opt/Thinkbox/Deadline10 \
    --connectiontype Remote \
    --remoteserver "${DEADLINE_REPO_IP}" \
    --remoteport 4433 \
    --noguimode true \
    --slavestartup true \
    --launcherdaemon true \
    --installlauncher false \
    --installclient true \
    --pools "${DEADLINE_POOL}" \
    --groups "${DEADLINE_GROUP}"

echo "==> [05] Configuring systemd override..."
systemctl disable deadline10launcher.service 2>/dev/null || true

mkdir -p /etc/systemd/system/deadline10launcher.service.d
cat > /etc/systemd/system/deadline10launcher.service.d/override.conf << 'UNIT'
[Unit]
After=network-online.target zerotier-one.service houdini-ubl.service rclone-b2-renders.service
Wants=network-online.target
UNIT

systemctl daemon-reload
systemctl enable deadline10launcher.service

rm -rf "$TMP_DIR"

echo "==> [05] Deadline Worker ${DEADLINE_VERSION} installed (service enabled, not started)"
echo "==> [05] Worker will connect to repo at ${DEADLINE_REPO_IP}:4433 over ZeroTier"

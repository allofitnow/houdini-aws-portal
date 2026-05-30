#!/usr/bin/env bash
# 05_deadline_worker.sh
# Install Thinkbox Deadline 10.4.2.3 Linux Worker and configure it to connect
# to the on-prem repository over the ZeroTier overlay network.
#
# Expects the installer in S3:
#   s3://$S3_BUCKET/installers/DeadlineClient-10.4.2.3-linux-x64-installer.run
#
# The worker is installed as a service but NOT started during AMI build.
# It starts on first boot after ZeroTier is authorized, UBL is configured for
# the selected worker region, and network connectivity is available.

S3_BUCKET="${S3_BUCKET:-CHANGE_ME}"
DEADLINE_REPO_IP="${DEADLINE_REPO_IP:-CHANGE_ME}"   # ZeroTier IP of on-prem repo
DEADLINE_VERSION="10.4.2.3"
DEADLINE_POOL="houdini-aws-gpu"
DEADLINE_GROUP="linux-gpu"
AWS_REGION="${AWS_REGION:-us-west-2}"
INSTALLER="DeadlineClient-${DEADLINE_VERSION}-linux-x64-installer.run"

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1
set -euo pipefail

echo "==>"

TMP_DIR=$(mktemp -d)

aws s3 cp "s3://${S3_BUCKET}/installers/${INSTALLER}" "${TMP_DIR}/${INSTALLER}" \
    --region "$AWS_REGION"

chmod +x "${TMP_DIR}/${INSTALLER}"

# Silent install — worker only, no Monitor, no Repository
# Flags verified against 'DeadlineClient-10.4.2.3-linux-x64-installer.run --help'
# Remote connection uses --proxyrootdir (host:port of RCS), not --remoteserver
# Pool/Group are configured post-install via deadlinecommand
"${TMP_DIR}/${INSTALLER}" \
    --mode unattended \
    --prefix /opt/Thinkbox/Deadline10 \
    --connectiontype Remote \
    --proxyrootdir "${DEADLINE_REPO_IP}:4433" \
    --noguimode true \
    --slavestartup true \
    --launcherdaemon true

# Do not start the worker now — it will start on first boot once ZT is authorized
# May fail on fresh install if unit not yet loaded — non-fatal
systemctl disable deadline10launcher.service 2>/dev/null || true

# Write a boot-order aware override: start Deadline only after ZT is up and UBL is ready
mkdir -p /etc/systemd/system/deadline10launcher.service.d
cat > /etc/systemd/system/deadline10launcher.service.d/override.conf << 'UNIT'
[Unit]
After=network-online.target zerotier-one.service houdini-ubl.service rclone-b2-renders.service
Wants=network-online.target
UNIT

systemctl daemon-reload
# Re-enable so it starts on subsequent boots (worker waits for ZT auth on first)
systemctl enable deadline10launcher.service

# Configure pool and group via deadlinecommand after install
/opt/Thinkbox/Deadline10/bin/deadlinecommand -SetMachinePools "$(hostname)" "${DEADLINE_POOL}" 2>/dev/null || \
    echo "WARNING: Could not set pool (may need repo connectivity)"
/opt/Thinkbox/Deadline10/bin/deadlinecommand -SetMachineGroups "$(hostname)" "${DEADLINE_GROUP}" 2>/dev/null || \
    echo "WARNING: Could not set group (may need repo connectivity)"

rm -rf "$TMP_DIR"

echo "==> [05] Deadline Worker ${DEADLINE_VERSION} installed (service enabled, not started)"
echo "==> [05] Worker will connect to repo at ${DEADLINE_REPO_IP}:4433 over ZeroTier"

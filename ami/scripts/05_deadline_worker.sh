#!/usr/bin/env bash
# 05_deadline_worker.sh
# Install Thinkbox Deadline 10.4.2.3 Linux Worker for Spot Event Plugin.
# Connects via Remote connection type to the ZeroTier IP of the RCS.
# Preconditions: S3_BUCKET and AWS_REGION are exported by build.sh.

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1
set -euo pipefail

echo "==> [05] Deadline Worker install started at $(date)"

S3_BUCKET="${S3_BUCKET:?S3_BUCKET must be set by build.sh}"
AWS_REGION="${AWS_REGION:-us-west-2}"
DEADLINE_VERSION="10.4.2.3"
INSTALLER="DeadlineClient-${DEADLINE_VERSION}-linux-x64-installer.run"
INSTALL_PREFIX="/opt/Thinkbox/Deadline10"
DEADLINE_VAR="/var/lib/Thinkbox/Deadline10"

# ── Idempotency check ────────────────────────────────────────────────────────
if [[ -x "${INSTALL_PREFIX}/bin/deadlinecommand" ]]; then
    echo "==> [05] Deadline Worker already installed, skipping installer"
else
    # ── Download installer from S3 ───────────────────────────────────────────
    TMP_DIR=$(mktemp -d)
    aws s3 cp "s3://${S3_BUCKET}/installers/${INSTALLER}" "${TMP_DIR}/${INSTALLER}" \
        --region "$AWS_REGION"
    chmod +x "${TMP_DIR}/${INSTALLER}"

    "${TMP_DIR}/${INSTALLER}" \
        --mode unattended \
        --prefix "${INSTALL_PREFIX}" \
        --connectiontype Remote \
        --proxyrootdir "10.147.18.89:4433" \
        --noguimode true \
        --slavestartup true \
        --launcherdaemon true \
        --daemonuser root

    rm -rf "${TMP_DIR}"
fi

# ── Install CA Certificate ───────────────────────────────────────────────────
# Deadline launcher runs as root (HOME=/root) and reads certs from its own
# config tree, not /var/lib. Install ca.crt in both locations.
mkdir -p "${DEADLINE_VAR}/certs"
DEADLINE_ROOT="/root/Thinkbox/Deadline10"
mkdir -p "${DEADLINE_ROOT}/certs"
# The build script expects ca.crt to be present in the ami/ directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/../ca.crt" ]]; then
    cp "$SCRIPT_DIR/../ca.crt" "${DEADLINE_VAR}/certs/ca.crt"
    chmod 644 "${DEADLINE_VAR}/certs/ca.crt"
    cp "$SCRIPT_DIR/../ca.crt" "${DEADLINE_ROOT}/certs/ca.crt"
    chmod 644 "${DEADLINE_ROOT}/certs/ca.crt"
    echo "==> [05] Copied ca.crt to worker certs directories"
else
    echo "==> [05] WARNING: ca.crt not found at $SCRIPT_DIR/../ca.crt. SSL may fail."
fi

# ── Systemd override: ensure boot after ZeroTier, B2 and UBL ───────────────
SERVICE_FILE="/etc/systemd/system/deadline10launcher.service"
if [[ ! -f "$SERVICE_FILE" ]]; then
    cat > "$SERVICE_FILE" << 'UNIT'
[Unit]
Description=Deadline 10 Launcher
After=zerotier-auto-join.service rclone-b2-renders.service houdini-ubl.service network-online.target
Wants=zerotier-auto-join.service rclone-b2-renders.service houdini-ubl.service network-online.target

[Service]
Type=simple
ExecStart=/opt/Thinkbox/Deadline10/bin/deadlinelauncher -nogui
Restart=on-failure
RestartSec=10
Environment=HOME=/root
Environment=QT_QPA_PLATFORM=offscreen

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    echo "==> [05] Created deadline10launcher.service systemd unit"
fi

OVERRIDE_DIR="/etc/systemd/system/deadline10launcher.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"
mkdir -p "$OVERRIDE_DIR"
cat > "$OVERRIDE_FILE" << 'UNIT'
[Unit]
After=zerotier-auto-join.service rclone-b2-renders.service houdini-ubl.service network-online.target
Wants=zerotier-auto-join.service rclone-b2-renders.service houdini-ubl.service network-online.target
UNIT
systemctl daemon-reload

# ── Enable launcher service ──────────────────────────────────────────────────
systemctl enable deadline10launcher.service

# ── Ensure deadline.ini has correct Static IP and SSL settings ──────────
# The installer writes its own deadline.ini under /root/Thinkbox/Deadline10.
# Launcher runs as root (HOME=/root) so that copy wins. We must configure
# BOTH /var/lib and /root copies identically.
DEADLINE_INI='[Deadline]
ConnectionType=Remote
ProxyRoot=10.147.18.89:4433
ProxyUseSSL=True
ProxySSLCertificate=/root/Thinkbox/Deadline10/certs/Deadline10Client.pfx
ProxySSLCA=/root/Thinkbox/Deadline10/certs/ca.crt
ClientSSLAuthentication=Required
LaunchSlaveAtStartup=true
NoGuiMode=true'

mkdir -p "${DEADLINE_VAR}"
printf '%s\n' "$DEADLINE_INI" > "${DEADLINE_VAR}/deadline.ini"
printf '%s\n' "$DEADLINE_INI" > "${DEADLINE_ROOT}/deadline.ini"
echo "==> [05] Wrote deadline.ini to /var/lib and /root Thinkbox paths"

# ── Ensure slaves directory exists and is writable ─────────────────────
mkdir -p "${DEADLINE_VAR}/slaves"
chmod 777 "${DEADLINE_VAR}/slaves"

echo "==> [05] Deadline Worker installed and configured for Spot Event Plugin (ZeroTier IP)"

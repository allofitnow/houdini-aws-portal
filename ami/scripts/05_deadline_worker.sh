#!/usr/bin/env bash
# 05_deadline_worker.sh
# Install Thinkbox Deadline 10.4.2.3 Linux Worker for AWS Portal.
# Connects via Remote connection type with empty ProxyRoot — Portal user-data
# sets Region=<stack-name> at runtime for Gateway discovery.
# Preconditions: S3_BUCKET and AWS_REGION are exported by build.sh.
#   Step 01 (system prep) must be complete (python symlink, ec2-user, etc.).

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

    # ── Unattended install ───────────────────────────────────────────────────
    # Remote connection with EMPTY proxy root — Portal user-data configures the
    # actual RCS endpoint at instance launch via Region=<stack-name>.
    # --slavestartup false: Portal user-data enables the slave after config.
    # --daemonuser root: Portal launcher runs as root.
    "${TMP_DIR}/${INSTALLER}" \
        --mode unattended \
        --prefix "${INSTALL_PREFIX}" \
        --connectiontype Remote \
        --proxyrootdir "" \
        --noguimode true \
        --slavestartup false \
        --launcherdaemon true \
        --daemonuser root

    rm -rf "${TMP_DIR}"
fi

# ── Disable launcher service — Portal user-data starts it after config ───────
# May fail if unit not yet loaded on first install — non-fatal.
systemctl disable deadline10launcher.service 2>/dev/null || true

# ── Systemd override: boot after UBL and network ────────────────────────────
# Portal builds have no ZeroTier and no rclone — only UBL + network-online.
OVERRIDE_DIR="/etc/systemd/system/deadline10launcher.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"
if [[ ! -f "$OVERRIDE_FILE" ]]; then
    mkdir -p "$OVERRIDE_DIR"
    cat > "$OVERRIDE_FILE" << 'UNIT'
[Unit]
After=houdini-ubl.service network-online.target
Wants=network-online.target
UNIT
    systemctl daemon-reload
fi
# Service stays disabled — Portal user-data enables and starts it at launch.

# ── Ensure deadline.ini has Portal-compatible defaults ───────────────────────
mkdir -p "${DEADLINE_VAR}"
INI_FILE="${DEADLINE_VAR}/deadline.ini"
if [[ ! -f "$INI_FILE" ]]; then
    cat > "$INI_FILE" << INIEOF
ConnectionType=Remote
ProxyRoot=
LaunchSlaveAtStartup=false
INIEOF
else
    # Patch existing file to ensure Portal-compatible values
    sed -i 's/^ConnectionType=.*/ConnectionType=Remote/' "$INI_FILE" 2>/dev/null || true
    sed -i 's/^ProxyRoot=.*/ProxyRoot=/' "$INI_FILE" 2>/dev/null || true
    sed -i 's/^LaunchSlaveAtStartup=.*/LaunchSlaveAtStartup=false/' "$INI_FILE" 2>/dev/null || true
fi

# ── Ensure slaves directory exists and is writable ───────────────────────────
mkdir -p "${DEADLINE_VAR}/slaves"
chmod 777 "${DEADLINE_VAR}/slaves"

# ── Ensure /home/ec2-user/.aws/ directory exists ────────────────────────────
# Created by 01_system_prep.sh but ensure it exists in case of re-runs.
mkdir -p /home/ec2-user/.aws
chown -R ec2-user:ec2-user /home/ec2-user/.aws

# ── CloudWatch shim scripts ──────────────────────────────────────────────────
# Portal user-data may call these helpers. If the Deadline installer did not
# create them, provide no-op shims so the boot sequence does not fail.

CW_SETUP_BIN="/opt/Thinkbox/CloudWatchSetup/bin"
CW_DIR="/opt/Thinkbox/CloudWatch"

mkdir -p "$CW_SETUP_BIN" "$CW_DIR"

# set_awslogs_region.py — no-op shim
CW_REGION_SCRIPT="${CW_SETUP_BIN}/set_awslogs_region.py"
if [[ ! -f "$CW_REGION_SCRIPT" ]]; then
    cat > "$CW_REGION_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""No-op shim: Portal does not use CloudWatch agent configuration."""
pass
PYEOF
    chmod +x "$CW_REGION_SCRIPT"
fi

# add_awslogs_stream_name_prefix.py — no-op shim
CW_PREFIX_SCRIPT="${CW_SETUP_BIN}/add_awslogs_stream_name_prefix.py"
if [[ ! -f "$CW_PREFIX_SCRIPT" ]]; then
    cat > "$CW_PREFIX_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""No-op shim: Portal does not use CloudWatch agent configuration."""
pass
PYEOF
    chmod +x "$CW_PREFIX_SCRIPT"
fi

# on_instance_init.sh — no-op shim
CW_INIT_SCRIPT="${CW_DIR}/on_instance_init.sh"
if [[ ! -f "$CW_INIT_SCRIPT" ]]; then
    cat > "$CW_INIT_SCRIPT" << 'BASHEOF'
#!/usr/bin/env bash
# No-op shim: Portal does not use CloudWatch on-instance init.
exit 0
BASHEOF
    chmod +x "$CW_INIT_SCRIPT"
fi

echo "==> [05] Deadline Worker ${DEADLINE_VERSION} installed (service disabled, Portal-ready)"
echo "==> [05] Connection: Remote with empty ProxyRoot — Portal user-data configures at launch"

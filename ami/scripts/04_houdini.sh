#!/usr/bin/env bash
# 04_houdini.sh
# Install Houdini 21.0 in headless/non-interactive mode and configure UBL.
#
# Expects the Houdini 21.0 Linux installer tarball in S3:
#   s3://$S3_BUCKET/installers/houdini-21.0.<build>-linux_x86_64_gcc11.2.tar.gz
#
# UBL server token is fetched from AWS Secrets Manager at boot via
# /usr/local/sbin/houdini-ubl-init.sh (installed here).
# Do NOT store the UBL token in the AMI.

S3_BUCKET="${S3_BUCKET:-CHANGE_ME}"
HOUDINI_VERSION="${HOUDINI_VERSION:-21.0}"
HOUDINI_BUILD="${HOUDINI_BUILD:-CHANGE_ME}"   # e.g. 506  -> houdini-21.0.506
INSTALL_DIR="/opt/hfs${HOUDINI_VERSION}"
AWS_REGION="${AWS_REGION:-us-west-2}"

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1

echo "==> [04] Houdini ${HOUDINI_VERSION} install started at $(date)"

TARBALL="houdini-${HOUDINI_VERSION}.${HOUDINI_BUILD}-linux_x86_64_gcc11.2.tar.gz"
TMP_DIR=$(mktemp -d)

# Download installer from S3
aws s3 cp "s3://${S3_BUCKET}/installers/${TARBALL}" "${TMP_DIR}/${TARBALL}" \
    --region "$AWS_REGION"

tar -xzf "${TMP_DIR}/${TARBALL}" -C "$TMP_DIR"
INSTALLER_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name "houdini-*" | head -1)

# Silent install: engine only (no GUI, no desktop launcher)
"${INSTALLER_DIR}/houdini.install" \
    --accept-EULA 2021-10-13 \
    --install-houdini \
    --install-houdini-engine \
    --no-install-license \
    --no-install-hqueue-client \
    --no-install-hqueue-server \
    --no-install-menus \
    --no-install-bin-symlink \
    --make-dir "${INSTALL_DIR}"

# Source Houdini environment for subsequent steps
echo "source ${INSTALL_DIR}/houdini_setup" >> /etc/profile.d/houdini.sh
chmod +x /etc/profile.d/houdini.sh

# Verify headless render binary
source "${INSTALL_DIR}/houdini_setup" 2>/dev/null || true
hython --version || {
    echo "ERROR: hython not found after Houdini install"
    exit 1
}

# Write boot-time UBL init script (credentials injected from Secrets Manager)
cat > /usr/local/sbin/houdini-ubl-init.sh << 'BOOTSCRIPT'
#!/usr/bin/env bash
# Fetches the SideFX UBL server token and writes the sesinetd config.
# Called by houdini-ubl.service on each boot.
AWS_REGION="${AWS_REGION:-us-west-2}"
UBL_TOKEN=$(aws secretsmanager get-secret-value \
    --region "$AWS_REGION" \
    --secret-id "houdini/ubl-token" \
    --query SecretString --output text)

mkdir -p /etc/sesi
cat > /etc/sesi/sesinetd.conf << EOF
[LICENSE_SERVER]
server = sesinetd.sidefx.com
token = ${UBL_TOKEN}
EOF
chmod 600 /etc/sesi/sesinetd.conf
BOOTSCRIPT
chmod 700 /usr/local/sbin/houdini-ubl-init.sh

# systemd unit to run UBL init before Deadline worker starts
cat > /etc/systemd/system/houdini-ubl.service << 'UNIT'
[Unit]
Description=Initialize SideFX Houdini UBL token
After=network-online.target
Wants=network-online.target
Before=deadline-worker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/houdini-ubl-init.sh

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable houdini-ubl.service

# Cleanup installer files
rm -rf "$TMP_DIR"

echo "==> [04] Houdini ${HOUDINI_VERSION}.${HOUDINI_BUILD} install complete"

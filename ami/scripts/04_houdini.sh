#!/usr/bin/env bash
# 04_houdini.sh
# Install Houdini 21.0 in headless/non-interactive mode and configure
# AWS Deadline Cloud UBL licensing.
#
# Licensing method: AWS Deadline Cloud UBL (license endpoint in AWS VPC)
#   - Workers set HOUDINI_LICENSE_SERVER to the Deadline Cloud license endpoint DNS
#   - Endpoint is created via: aws deadline create-license-endpoint (see issue #9)
#   - Endpoint DNS is stored in Secrets Manager as: houdini/license-endpoint-dns
#   - Billed through AWS — no SideFX token or sesinetd config required
#   - Required inbound on worker SG: TCP 1715-1717 from the license endpoint
#
# NOTE: houdini/license-endpoint-dns value is PENDING until the Deadline Cloud
# license endpoint is created (issue #9). The worker will fail to acquire a
# license until that secret is updated with the real endpoint DNS.
#
# Expects the Houdini 21.0 Linux installer tarball in S3:
#   s3://$S3_BUCKET/installers/houdini-21.0.<build>-linux_x86_64_gcc11.2.tar.gz

S3_BUCKET="${S3_BUCKET:-CHANGE_ME}"
HOUDINI_VERSION="${HOUDINI_VERSION:-21.0}"
HOUDINI_BUILD="${HOUDINI_BUILD:-CHANGE_ME}"
INSTALL_DIR="/opt/hfs${HOUDINI_VERSION}"
AWS_REGION="${AWS_REGION:-us-west-2}"

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1
set -euo pipefail

echo "==>"

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
echo "source ${INSTALL_DIR}/houdini_setup" > /etc/profile.d/houdini.sh
chmod +x /etc/profile.d/houdini.sh

# Verify headless render binary
# houdini_setup may not exist during dry-run review — non-fatal
# shellcheck source=/dev/null
source "${INSTALL_DIR}/houdini_setup" 2>/dev/null || true
hython --version || {
    echo "ERROR: hython not found after Houdini install"
    exit 1
}

# --- Deadline Cloud UBL licensing ---
# Write a boot-time service that fetches the Deadline Cloud license endpoint
# DNS from Secrets Manager and sets HOUDINI_LICENSE_SERVER for all processes.
#
# The endpoint DNS is stored as: houdini/license-endpoint-dns
# Create the endpoint with:
#   aws deadline create-license-endpoint --vpc-id <VPC> --subnet-ids <SUBNET> \
#       --security-group-ids <SG> --region us-west-2
# Then add Houdini as a metered product:
#   aws deadline create-metered-product --license-endpoint-id <ID> \
#       --vendor sidefx --product houdini --region us-west-2
# Then update the secret:
#   aws secretsmanager put-secret-value --secret-id houdini/license-endpoint-dns \
#       --secret-string <ENDPOINT_DNS>

cat > /usr/local/sbin/houdini-ubl-init.sh << 'BOOTSCRIPT'
#!/usr/bin/env bash
# Fetches the Deadline Cloud UBL license endpoint DNS and writes it to
# /etc/profile.d/houdini-license.sh so all Houdini processes find the server.
# Called by houdini-ubl.service on each boot.
AWS_REGION="${AWS_REGION:-us-west-2}"

LICENSE_DNS=$(aws secretsmanager get-secret-value \
    --region "$AWS_REGION" \
    --secret-id "houdini/license-endpoint-dns" \
    --query SecretString --output text 2>/dev/null)

if [[ -z "$LICENSE_DNS" || "$LICENSE_DNS" == "PENDING" ]]; then
    echo "WARNING: houdini/license-endpoint-dns is not set. Houdini UBL will not work."
    echo "         Create the Deadline Cloud license endpoint (see issue #9) and update the secret."
    exit 0
fi

# Write system-wide env var — picked up by hbatch, hython, karma, mantra
cat > /etc/profile.d/houdini-license.sh << EOF
# Deadline Cloud UBL — set by houdini-ubl.service at boot
export HOUDINI_LICENSE_SERVER=${LICENSE_DNS}
EOF
chmod 644 /etc/profile.d/houdini-license.sh

echo "Houdini license server set to: ${LICENSE_DNS}"
BOOTSCRIPT
chmod 700 /usr/local/sbin/houdini-ubl-init.sh

# systemd unit — runs before Deadline worker starts
cat > /etc/systemd/system/houdini-ubl.service << 'UNIT'
[Unit]
Description=Configure Houdini Deadline Cloud UBL license endpoint
After=network-online.target
Wants=network-online.target
Before=deadline10launcher.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/houdini-ubl-init.sh

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable houdini-ubl.service

rm -rf "$TMP_DIR"

echo "==> [04] Houdini ${HOUDINI_VERSION}.${HOUDINI_BUILD} install complete"
echo "==> [04] UBL: license endpoint DNS will be set at boot from houdini/license-endpoint-dns secret"

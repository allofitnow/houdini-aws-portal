#!/usr/bin/env bash
# 04_houdini.sh
# Install Houdini 21.0 in headless/non-interactive mode and configure
# AWS Deadline Cloud UBL licensing for AL2023.
#
# Preconditions:
#   - AL2023 EC2 instance with AWS CLI v2 and sufficient disk space
#   - Environment vars set by build.sh: S3_BUCKET, HOUDINI_BUILD,
#     HOUDINI_VERSION, AWS_REGION, HOUDINI_LICENSE_ENDPOINT_SECRET_ID
#   - Houdini Linux installer tarball uploaded to
#     s3://$S3_BUCKET/installers/houdini-21.0.<build>-linux_x86_64_gcc11.2.tar.gz
#
# Licensing method: AWS Deadline Cloud UBL (license endpoint in AWS VPC)
#   - Workers set SideFX hserver to a chained Deadline Cloud license endpoint list
#   - Endpoint is created via: aws deadline create-license-endpoint (see issue #9)
#   - Endpoint DNS is stored on Secrets Manager as: houdini/license-endpoint-dns
#   - Billed through AWS — no SideFX token or local sesinetd required
#   - Required inbound on worker SG: TCP 1715-1717 from ReverseSlaveSG to itself
#
# NOTE: houdini/license-endpoint-dns value is PENDING until the Deadline Cloud
# license endpoint is created (issue #9). The worker will fail to acquire a
# license until that secret is updated with the real endpoint DNS.

S3_BUCKET="${S3_BUCKET:-CHANGE_ME}"
HOUDINI_VERSION="${HOUDINI_VERSION:-21.0}"
HOUDINI_BUILD="${HOUDINI_BUILD:-CHANGE_ME}"
INSTALL_DIR="/opt/hfs${HOUDINI_VERSION}"
AWS_REGION="${AWS_REGION:-us-west-2}"
HOUDINI_LICENSE_ENDPOINT_SECRET_ID="${HOUDINI_LICENSE_ENDPOINT_SECRET_ID:-houdini/license-endpoint-dns}"

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1
set -euo pipefail

echo "==> [04] Houdini install started at $(date)"

TARBALL="houdini-${HOUDINI_VERSION}.${HOUDINI_BUILD}-linux_x86_64_gcc11.2.tar.gz"
TMP_DIR=$(mktemp -d)

# Download installer from S3
aws s3 cp "s3://${S3_BUCKET}/installers/${TARBALL}" "${TMP_DIR}/${TARBALL}" \
    --region "$AWS_REGION"

tar -xzf "${TMP_DIR}/${TARBALL}" -C "$TMP_DIR"
INSTALLER_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name "houdini-*" | head -1)

# Silent install: headless render (no GUI, no desktop launcher, no license server)
"${INSTALLER_DIR}/houdini.install" \
    --accept-EULA 2021-10-13 \
    --install-houdini \
    --no-install-license \
    --no-install-hqueue-client \
    --no-install-hqueue-server \
    --no-install-menus \
    --no-install-bin-symlink \
    --make-dir "${INSTALL_DIR}"

# Source Houdini environment for subsequent steps
echo "source ${INSTALL_DIR}/houdini_setup" > /etc/profile.d/houdini.sh
chmod +x /etc/profile.d/houdini.sh

# Verify headless render binary. houdini_setup may not exist during dry-run review — non-fatal.
# shellcheck source=/dev/null
source "${INSTALL_DIR}/houdini_setup" 2>/dev/null || true  # tolerates missing file during image review
hython --version || {
    echo "ERROR: hython not found after Houdini install"
    exit 1
}

# --- Deadline Cloud UBL licensing ---
# Write a boot-time service that fetches the Deadline Cloud license endpoint
# DNS from Secrets Manager and sets HOUDINI_LICENSE_SERVER for all processes.
#
# The endpoint DNS is stored as the configured HOUDINI_LICENSE_ENDPOINT_SECRET_ID.
# Create the endpoint with:
#   aws deadline create-license-endpoint --vpc-id <VPC> --subnet-ids <SUBNET> \
#       --security-group-ids <SG> --region <REGION>
# Then attach the needed metered products:
#   aws deadline put-metered-product --license-endpoint-id <ID> \
#       --product-id houdini-21.0 --region <REGION>
#   aws deadline put-metered-product --license-endpoint-id <ID> \
#       --product-id karma-21.0 --region <REGION>
#   aws deadline put-metered-product --license-endpoint-id <ID> \
#       --product-id mantra-21.0 --region <REGION>
# Then update the secret:
#   aws secretsmanager put-secret-value --secret-id "$HOUDINI_LICENSE_ENDPOINT_SECRET_ID" \
#       --secret-string <ENDPOINT_DNS>

cat > /usr/local/sbin/houdini-ubl-init.sh << 'BOOTSCRIPT'
#!/usr/bin/env bash
# Fetches the Deadline Cloud UBL license endpoint DNS and writes it to
# /etc/profile.d/houdini-license.sh so all Houdini processes find the server.
# Called by houdini-ubl.service on each boot.
DEFAULT_FILE="/etc/default/houdini-ubl"
if [[ -f "$DEFAULT_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$DEFAULT_FILE"
fi

AWS_REGION="${AWS_REGION:-us-west-2}"
HOUDINI_LICENSE_ENDPOINT_SECRET_ID="${HOUDINI_LICENSE_ENDPOINT_SECRET_ID:-houdini/license-endpoint-dns}"

LICENSE_DNS=$(aws secretsmanager get-secret-value \
    --region "$AWS_REGION" \
    --secret-id "$HOUDINI_LICENSE_ENDPOINT_SECRET_ID" \
    --query SecretString --output text 2>/dev/null)

if [[ -z "$LICENSE_DNS" || "$LICENSE_DNS" == "PENDING" ]]; then
    echo "WARNING: ${HOUDINI_LICENSE_ENDPOINT_SECRET_ID} is not set in ${AWS_REGION}. Houdini UBL will not work."
    echo "         Create the regional Deadline Cloud license endpoint and update the secret."
    exit 0
fi

# SideFX products are exposed by Deadline Cloud UBL on separate ports.
# hserver supports semicolon-separated license server chaining, which lets
# Houdini, Karma, and Mantra find their product-specific endpoint ports.
LICENSE_CHAIN="${LICENSE_DNS}:1715;${LICENSE_DNS}:1716;${LICENSE_DNS}:1717"

# Write system-wide env vars — picked up by Deadline, hbatch, hython, karma, mantra.
cat > /etc/profile.d/houdini-license.sh << EOF
# Deadline Cloud UBL — set by houdini-ubl.service at boot
export HOUDINI_LICENSE_SERVER='${LICENSE_CHAIN}'
export SESI_LMHOST='${LICENSE_CHAIN}'
export QT_QPA_PLATFORM=offscreen
EOF
chmod 644 /etc/profile.d/houdini-license.sh

# Persist hserver's license search list for root, ec2-user, and the system hserver user.
install -d -m 755 /usr/lib/sesi/hserver /home/ec2-user
printf 'serverhost=%s\n' "$LICENSE_CHAIN" > /usr/lib/sesi/hserver/.sesi_licenses.pref
printf 'serverhost=%s\n' "$LICENSE_CHAIN" > /root/.sesi_licenses.pref
printf 'serverhost=%s\n' "$LICENSE_CHAIN" > /home/ec2-user/.sesi_licenses.pref
chown ec2-user:ec2-user /home/ec2-user/.sesi_licenses.pref 2>/dev/null || true  # tolerates missing user during image bake
chmod 644 /usr/lib/sesi/hserver/.sesi_licenses.pref /root/.sesi_licenses.pref /home/ec2-user/.sesi_licenses.pref

# Restart hserver if it was launched before the endpoint was configured.
pkill -f hserver 2>/dev/null || true  # hserver may not be running during initial bake

echo "Houdini license server chain set to: ${LICENSE_CHAIN}"
BOOTSCRIPT
chmod 700 /usr/local/sbin/houdini-ubl-init.sh

cat > /etc/default/houdini-ubl << EOF
# Defaults used by houdini-ubl.service; launch scripts may override these per worker region.
AWS_REGION=${AWS_REGION}
HOUDINI_LICENSE_ENDPOINT_SECRET_ID=${HOUDINI_LICENSE_ENDPOINT_SECRET_ID}
EOF
chmod 644 /etc/default/houdini-ubl

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
echo "==> [04] UBL: license endpoint DNS will be set at boot from ${HOUDINI_LICENSE_ENDPOINT_SECRET_ID} in ${AWS_REGION}"

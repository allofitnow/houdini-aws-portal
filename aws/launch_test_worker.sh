#!/bin/bash
# worker-bootstrap.sh
# Full worker bootstrap for on-demand test instances (option C).
# Run as UserData on a fresh AL2023 instance with the deadline-worker-profile IAM role.
#
# Covers: ZeroTier join + SSL certs + Deadline RCS config + rclone B2 mount
#         + Houdini/UBL env vars + deadlinecommand symlink + render output symlink
set -ex

export AWS_REGION=us-west-2
RCS_HOSTNAME="ATXRTX"
RCS_IP="10.147.18.89"
CERTS_DIR="/root/Thinkbox/Deadline10/certs"
S3_CERTS="s3://aoin-renderfarm-staging/deadline-certs"
ZT_NETWORK="d3ecf5726d14ac76"
B2_BUCKET="aoin-test"

# ─── 1. /etc/hosts (RCS cert SAN matching) ───
echo "${RCS_IP} ${RCS_HOSTNAME}" >> /etc/hosts

# ─── 2. Download SSL certs from S3 ───
mkdir -p "${CERTS_DIR}"
aws s3 sync "${S3_CERTS}" "${CERTS_DIR}/" --region "${AWS_REGION}"

# Convert DER server cert to PEM (for OpenSSL/SSL_CERT_FILE)
openssl x509 -inform DER -in "${CERTS_DIR}/DeadlineRCSServer.cer" \
  -out "${CERTS_DIR}/DeadlineRCSServer.pem" 2>/dev/null || \
openssl x509 -inform PEM -in "${CERTS_DIR}/DeadlineRCSServer.cer" \
  -out "${CERTS_DIR}/DeadlineRCSServer.pem"

chmod 644 "${CERTS_DIR}"/*

# Install server cert + CA into OS trust store
cp "${CERTS_DIR}/DeadlineRCSServer.pem" /etc/pki/ca-trust/source/anchors/DeadlineRCSServer.crt
cp "${CERTS_DIR}/ca.crt" /etc/pki/ca-trust/source/anchors/DeadlineCA.crt 2>/dev/null || true
update-ca-trust

# ─── 3. Wait for ZeroTier to assign an IP ───
# The zerotier-auto-join.service (from AMI) handles join + authorize.
# We wait for the managed IP here so we can set HostMachineIPAddressOverride.
ZT_IP=""
for i in $(seq 1 60); do
    ZT_IP=$(zerotier-cli listnetworks 2>/dev/null | awk -v net="${ZT_NETWORK}" '$1==net||$3==net{print $NF}' | cut -d/ -f1)
    if [[ -n "${ZT_IP}" ]]; then
        echo "ZeroTier IP acquired: ${ZT_IP}"
        break
    fi
    echo "Waiting for ZeroTier IP... (${i}/60)"
    sleep 5
done

if [[ -z "${ZT_IP}" ]]; then
    echo "WARNING: No ZeroTier IP after 5 min. RCS connectivity may fail."
    ZT_IP="0.0.0.0"
fi

# Set system hostname to ZT IP so Deadline RemoteLog can resolve the worker
# without DNS (AWS private hostnames like ip-172-31-x-x are not routable on-prem).
hostnamectl set-hostname "$ZT_IP"

# ─── 4. Write deadline.ini to BOTH locations ───
DEADLINE_INI="[Deadline]
ConnectionType=Remote
ProxyRoot=${RCS_HOSTNAME}:4433
ProxyUseSSL=True
ProxySSLCertificate=${CERTS_DIR}/Deadline10Client.pfx
ProxySSLCA=
ClientSSLAuthentication=Required
LaunchSlaveAtStartup=true
NoGuiMode=true
HostMachineIPAddressOverride=${ZT_IP}
SlaveHostMachineIPAddressOverride=${ZT_IP}
"

for INI_PATH in /root/Thinkbox/Deadline10/deadline.ini /var/lib/Thinkbox/Deadline10/deadline.ini; do
  mkdir -p "$(dirname "${INI_PATH}")"
  echo "${DEADLINE_INI}" > "${INI_PATH}"
  chmod 644 "${INI_PATH}"
done

# ─── 5. Systemd override for .NET SSL + Houdini/UBL env vars ───
# Fetch UBL license endpoint DNS from Secrets Manager
UBL_ENDPOINT=$(aws secretsmanager get-secret-value \
    --region "${AWS_REGION}" \
    --secret-id "houdini/license-endpoint-dns" \
    --query SecretString --output text 2>/dev/null || echo "")

mkdir -p /etc/systemd/system/deadline10launcher.service.d
cat > /etc/systemd/system/deadline10launcher.service.d/ssl.conf << SSLCONF
[Service]
# .NET SSL fix for Linux (self-signed RCS cert)
Environment="DOTNET_SYSTEM_NET_HTTP_USESOCKETSHTTPHANDLER=0"
Environment="SSL_CERT_FILE=${CERTS_DIR}/DeadlineRCSServer.pem"
Environment="SSL_CERT_DIR=/etc/pki/ca-trust/extracted/pem/"

# Houdini environment
Environment="HFS=/opt/hfs21.0"
Environment="PATH=/opt/hfs21.0/bin:/opt/Thinkbox/Deadline10/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="LD_LIBRARY_PATH=/opt/hfs21.0/dsolib"

# UBL license server
Environment="HOUDINI_LICENSE_SERVER=${UBL_ENDPOINT}"
Environment="SESI_LMHOST=${UBL_ENDPOINT}"
SSLCONF

systemctl daemon-reload

# ─── 6. deadlinecommand symlink (Houdini plugin needs it in PATH) ───
ln -sf /opt/Thinkbox/Deadline10/bin/deadlinecommand /usr/local/bin/deadlinecommand

# ─── 7. Install rclone + fuse3, mount B2 ───
curl -fsSL https://rclone.org/install.sh | bash
dnf install -y fuse3

# Fetch B2 credentials from Secrets Manager
B2_KEY_ID=$(aws secretsmanager get-secret-value \
    --region "${AWS_REGION}" \
    --secret-id "backblaze/b2-key-id" \
    --query SecretString --output text)

B2_APP_KEY=$(aws secretsmanager get-secret-value \
    --region "${AWS_REGION}" \
    --secret-id "backblaze/b2-app-key" \
    --query SecretString --output text)

mkdir -p /etc/rclone
chmod 700 /etc/rclone
cat > /etc/rclone/rclone.conf << RCLONECONF
[b2renders]
type = b2
account = ${B2_KEY_ID}
key = ${B2_APP_KEY}
hard_delete = false
RCLONECONF
chmod 600 /etc/rclone/rclone.conf

# Clear secrets from env
unset B2_KEY_ID B2_APP_KEY

# Mount B2 bucket
mkdir -p /mnt/renders
chmod 755 /mnt/renders
rclone mount "b2renders:${B2_BUCKET}" /mnt/renders \
    --config /etc/rclone/rclone.conf \
    --vfs-cache-mode writes \
    --vfs-cache-max-size 10G \
    --allow-other \
    --daemon

# Verify mount
sleep 3
if mountpoint -q /mnt/renders; then
    echo "B2 mount SUCCESS: /mnt/renders"
else
    echo "B2 mount FAILED"
fi

# ─── 8. Render output symlink ───
# The Karma ROP in the scene outputs to ~/renderkarma.
# Symlink it to the B2 mount so frames land in the cloud bucket.
rm -rf /home/ec2-user/renderkarma
ln -sfn /mnt/renders /home/ec2-user/renderkarma
chown -h ec2-user:ec2-user /home/ec2-user/renderkarma

# ─── 9. Restart Deadline launcher ───
sleep 5
systemctl restart deadline10launcher

echo "=== Bootstrap complete ==="

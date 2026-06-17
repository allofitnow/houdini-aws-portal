#!/usr/bin/env bash
# 04b_rclone_b2.sh
# Install rclone and configure a Backblaze B2 FUSE mount at /mnt/renders.
#
# B2 credentials are NOT stored in this script or the AMI image.
# They are fetched from AWS Secrets Manager at first boot via the
# systemd unit installed here (rclone-b2-renders.service).
#
# Required Secrets Manager entries (set these before launching workers):
#   backblaze/b2-key-id    -> B2 Application Key ID
#   backblaze/b2-app-key   -> B2 Application Key
#
# Set B2_BUCKET to your target bucket name before running.
# Example: B2_BUCKET=renders-allofitnow

B2_BUCKET="${B2_BUCKET:-aoin-test}"
MOUNT_POINT="/mnt/renders"
RCLONE_CONF="/etc/rclone/rclone.conf"
AWS_REGION="${AWS_REGION:-us-west-2}"

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1
set -euo pipefail

echo "==>"

# Install rclone
curl -fsSL https://rclone.org/install.sh | bash

# Install fuse3 (required for rclone mount)
if command -v apt-get &>/dev/null; then
    apt-get install -y fuse3
elif command -v dnf &>/dev/null; then
    dnf install -y fuse3 fuse3-libs
fi

# Create mount point
mkdir -p "$MOUNT_POINT"
chmod 755 "$MOUNT_POINT"

# Create rclone config directory (credentials written at boot, not here)
mkdir -p /etc/rclone
chmod 700 /etc/rclone

# Write the boot-time credential injection + mount script
cat > /usr/local/sbin/rclone-b2-mount.sh << BOOTSCRIPT
#!/usr/bin/env bash
# Fetches B2 credentials from Secrets Manager and mounts the B2 bucket.
# Run by rclone-b2-renders.service on every boot.

AWS_REGION="${AWS_REGION}"
B2_BUCKET="${B2_BUCKET}"
MOUNT_POINT="${MOUNT_POINT}"
RCLONE_CONF="${RCLONE_CONF}"

B2_KEY_ID=\$(aws secretsmanager get-secret-value \
    --region "\$AWS_REGION" \
    --secret-id "backblaze/b2-key-id" \
    --query SecretString --output text)

B2_APP_KEY=\$(aws secretsmanager get-secret-value \
    --region "\$AWS_REGION" \
    --secret-id "backblaze/b2-app-key" \
    --query SecretString --output text)

# Write rclone config (overwrite on every boot so no stale creds persist)
cat > "\$RCLONE_CONF" << EOF
[b2renders]
type = b2
account = \$B2_KEY_ID
key = \$B2_APP_KEY
hard_delete = false
EOF
chmod 600 "\$RCLONE_CONF"

# Mount B2 bucket
rclone mount b2renders:\$B2_BUCKET \$MOUNT_POINT \
    --config "\$RCLONE_CONF" \
    --vfs-cache-mode writes \
    --vfs-cache-max-size 10G \
    --allow-other \
    --daemon
BOOTSCRIPT

chmod 700 /usr/local/sbin/rclone-b2-mount.sh

# ── Rclone B2 mount unit ─────────────────────────────────────────────────────
cat > /etc/systemd/system/rclone-b2-renders.service << 'UNIT'
[Unit]
Description=Mount Backblaze B2 render output bucket at /mnt/renders
After=network-online.target zerotier-one.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/rclone-b2-mount.sh
ExecStop=fusermount3 -u /mnt/renders
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
UNIT

# ── Render symlink service ───────────────────────────────────────────────────
# The test scene's Karma ROP writes to /tmp/renderkarma/<scene>.<rop>.####.exr.
# Redirect that path to the B2 mount so rendered frames are persisted to
# Backblaze without an upload step. The symlink is created at boot; individual
# jobs can repoint it to a job-specific subfolder under /mnt/renders/outputs/.
cat > /usr/local/sbin/render-symlink.sh << 'SYMLINK'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$MOUNT_POINT"
if [[ -d /tmp/renderkarma && ! -L /tmp/renderkarma ]]; then
    rm -rf /tmp/renderkarma
fi
if [[ ! -e /tmp/renderkarma ]]; then
    ln -s "$MOUNT_POINT" /tmp/renderkarma
fi
SYMLINK
chmod 700 /usr/local/sbin/render-symlink.sh

cat > /etc/systemd/system/render-symlink.service << 'UNIT'
[Unit]
Description=Render output symlink (/tmp/renderkarma -> /mnt/renders)
After=rclone-b2-renders.service
Before=deadline10launcher.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/render-symlink.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

# Install systemd units
systemctl daemon-reload
systemctl enable rclone-b2-renders.service
systemctl enable render-symlink.service

echo "==> [04b] rclone B2 setup complete"
echo "==> [04b] IMPORTANT: Set B2_BUCKET in this script before building AMI (current: ${B2_BUCKET})"
echo "==> [04b] Mount will be active at /mnt/renders after first boot (post ZT auth)"

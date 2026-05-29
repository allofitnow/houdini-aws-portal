#!/usr/bin/env bash
# 06_cleanup.sh
# Pre-AMI cleanup. Run immediately before creating the AMI snapshot.
# Removes installer caches, SSH host keys (regenerated on first boot),
# shell history, and any temporary credentials used during the build.

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1
set -euo pipefail

echo "==>"

# Package cache
apt-get clean
rm -rf /var/lib/apt/lists/*

# Installer temp files
rm -rf /tmp/* /var/tmp/*

# SSH host keys (will be regenerated on first boot)
rm -f /etc/ssh/ssh_host_*
# Ensure ssh-keygen runs on first boot to regenerate them
cat > /etc/rc.local << 'RCLOCAL'
#!/bin/bash
test -f /etc/ssh/ssh_host_rsa_key || dpkg-reconfigure openssh-server
RCLOCAL
chmod +x /etc/rc.local

# Shell history
history -c
cat /dev/null > /root/.bash_history
# ubuntu user may not exist on all AMIs — non-fatal
cat /dev/null > /home/ubuntu/.bash_history 2>/dev/null || true

# rclone config (contains no credentials yet, but wipe to be safe)
rm -f /etc/rclone/rclone.conf

# UBL config (contains no token yet since it's injected at boot, but wipe to be safe)
rm -f /etc/sesi/sesinetd.conf
rm -f /usr/lib/sesi/hserver/hserver.ini

# License env (regenerated at boot by houdini-ubl.service)
rm -f /etc/profile.d/houdini-license.sh

# Cloud-init cleanup so instance metadata is re-read on first boot
# cloud-init may not be installed — non-fatal
cloud-init clean --logs 2>/dev/null || true

echo "==> [06] Cleanup complete — instance is ready to image"

#!/usr/bin/env bash
# 06_cleanup.sh
# Pre-AMI cleanup. Run immediately before creating the AMI snapshot.
# Removes package caches, installer temp files, SSH host keys (regenerated
# on first boot), shell history, UBL config, and cloud-init state.
# Preconditions: All prior build scripts (01–05) completed successfully.

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1
set -euo pipefail

echo "==> [06] Cleanup started at $(date)"

# Package cache (AL2023 uses dnf)
dnf clean all
rm -rf /var/cache/dnf/*

# Installer temp files
rm -rf /tmp/* /var/tmp/*

# SSH host keys (will be regenerated on first boot)
rm -f /etc/ssh/ssh_host_*
# Ensure keys are regenerated on first boot via rc.local
cat > /etc/rc.local << 'RCLOCAL'
#!/bin/bash
ssh-keygen -A 2>/dev/null || true
systemctl restart sshd
# Remove self after first run so keys are only generated once
rm -f /etc/rc.local
RCLOCAL
chmod +x /etc/rc.local

# Shell history — root
history -c
cat /dev/null > /root/.bash_history

# Shell history — ec2-user may not exist yet — non-fatal
cat /dev/null > /home/ec2-user/.bash_history 2>/dev/null || true

# UBL config (contains no token yet since it's injected at boot, but wipe to be safe)
rm -f /etc/sesi/sesinetd.conf
rm -f /usr/lib/sesi/hserver/hserver.ini

# License env (regenerated at boot by houdini-ubl.service)
rm -f /etc/profile.d/houdini-license.sh

# Cloud-init cleanup so instance metadata is re-read on first boot
# cloud-init may not be installed — non-fatal
cloud-init clean --logs 2>/dev/null || true

echo "==> [06] Cleanup complete — instance is ready to image"

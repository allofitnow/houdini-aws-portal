#!/usr/bin/env bash
# 01_system_prep.sh
# System update, build/runtime dependencies, X11/GL/audio libs, Portal shims.
# Must be run as root on a fresh Amazon Linux 2023 instance.

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1
set -euo pipefail

echo "==> [01] System prep started at $(date)"

# ── System update ────────────────────────────────────────────────────────────
dnf update -y

# ── Build dependencies (for NVIDIA driver compile) ──────────────────────────
dnf install -y \
    gcc \
    make \
    "kernel-devel-$(uname -r)" \
    elfutils-libelf-devel

# ── Kernel modules (AL2023 minimal AMIs omit GPU/DRM modules) ──────────────
echo "==> [01] Installing kernel-modules-extra (DRM for NVIDIA driver)"
dnf install -y kernel-modules-extra || {
    echo "WARN: kernel-modules-extra install failed — NVIDIA driver may fail"
}

# ── Runtime dependencies ────────────────────────────────────────────────────
dnf install -y --allowerasing \
    python3 \
    python3-pip \
    tar \
    gzip \
    wget \
    curl \
    java-11-amazon-corretto-headless \
    jq \
    unzip \
    awscli

# ── GNOME Desktop (Xorg + all X11/GL/audio/font libraries for Houdini) ───────
# AL2023 "Desktop" group installs GNOME + Xorg + hundreds of libs including
# libOpenGL, libEGL, all X11 extensions, audio (alsa/PulseAudio), and fonts.
# Individual package installs below are no longer needed after this.
echo "==> [01] Installing GNOME Desktop group (X11 + display server for Houdini)"
dnf groupinstall -y "Desktop"

# ── Additional GL/EGL libraries (may already be satisfied by Desktop group) ──
dnf install -y \
    libglvnd-opengl \
    libglvnd-egl \
    mesa-libEGL \
    mesa-libGLU \
    ncurses-compat-libs

# ── Stack size fix (Houdini warns about 10MB default) ────────────────────────
grep -q 'soft stack unlimited' /etc/security/limits.conf 2>/dev/null || {
    echo "* soft stack unlimited" >> /etc/security/limits.conf
    echo "* hard stack unlimited" >> /etc/security/limits.conf
}

# ── Keep runlevel at multi-user (no auto-GUI; DCV/VNC provides display) ──────
systemctl set-default multi-user.target

# ── Portal shim: python → python3 symlink ────────────────────────────────────
# Portal user-data and Deadline helpers expect /usr/bin/python to exist.
if [[ ! -e /usr/bin/python ]]; then
    ln -sf /usr/bin/python3 /usr/bin/python
fi

# ── Portal shim: no-op awslogs systemd service ──────────────────────────────
# Portal user-data runs 'sudo service awslogs stop/start'. Provide a benign
# oneshot unit so those commands succeed without installing the full agent.
if [[ ! -f /etc/systemd/system/awslogs.service ]]; then
    cat > /etc/systemd/system/awslogs.service << 'AWSEOF'
[Unit]
Description=AWS Logs shim (no-op for Portal AMI)
DefaultDependencies=no
Before=shutdown.target

[Service]
Type=oneshot
ExecStart=/bin/true
ExecStop=/bin/true
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
AWSEOF
    systemctl daemon-reload
    systemctl enable awslogs.service
fi

# ── Portal shim: chkconfig wrapper ───────────────────────────────────────────
# Portal user-data calls 'chkconfig --add <svc>' and 'chkconfig <svc> on'.
# AL2023 has no chkconfig — provide a wrapper that translates to systemctl.
if [[ ! -x /sbin/chkconfig ]] || [[ -L /sbin/chkconfig ]]; then
    cat > /sbin/chkconfig << 'CHKWRAPPER'
#!/bin/bash
# chkconfig shim for AL2023 — translates to systemctl calls.
# Portal user-data uses: chkconfig --add <svc>, chkconfig <svc> on/off
case "${1:-}" in
    --add)
        # 'chkconfig --add <svc>' is a no-op on systemd — unit already exists
        shift
        systemctl daemon-reload 2>/dev/null
        exit 0
        ;;
    --del|--delete)
        shift
        systemctl disable "${1:-}" 2>/dev/null
        exit 0
        ;;
    --list)
        systemctl list-unit-files --type=service 2>/dev/null
        exit 0
        ;;
    -*)
        # Unknown flags — ignore
        exit 0
        ;;
    *)
        # 'chkconfig <svc> on' or 'chkconfig <svc> off'
        SVC="${1:-}"
        ACTION="${2:-on}"
        if [[ "$ACTION" == "on" ]]; then
            systemctl enable "$SVC" 2>/dev/null
        else
            systemctl disable "$SVC" 2>/dev/null
        fi
        exit 0
        ;;
esac
CHKWRAPPER
    chmod +x /sbin/chkconfig
fi

# ── Ensure ec2-user home and .aws directory ──────────────────────────────────
if ! getent passwd ec2-user >/dev/null 2>&1; then
    useradd -m -s /bin/bash ec2-user
fi
mkdir -p /home/ec2-user/.aws
chown -R ec2-user:ec2-user /home/ec2-user/.aws

# ── Blacklist Nouveau (conflicts with NVIDIA data center driver) ─────────────
if [[ ! -f /etc/modprobe.d/blacklist-nouveau.conf ]]; then
    cat > /etc/modprobe.d/blacklist-nouveau.conf << 'NOUVEAUEOF'
blacklist nouveau
options nouveau modeset=0
NOUVEAUEOF
fi
dracut --force

# ── Clean up ─────────────────────────────────────────────────────────────────
dnf clean all

echo "==> [01] System prep complete"

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

# ── X11 / GL libraries (Houdini UI and rendering) ───────────────────────────
dnf install -y \
    libXext \
    libX11 \
    libXmu \
    libXi \
    libXt \
    libXinerama \
    libXrandr \
    libXcursor \
    libXfixes \
    libXrender \
    libXScrnSaver \
    libSM \
    libICE \
    mesa-libGLU \
    mesa-libGL

# ── Audio ────────────────────────────────────────────────────────────────────
dnf install -y \
    alsa-lib

# ── Fonts ────────────────────────────────────────────────────────────────────
dnf install -y \
    liberation-sans-fonts \
    liberation-serif-fonts \
    liberation-mono-fonts

# ── Misc libraries ───────────────────────────────────────────────────────────
dnf install -y \
    ncurses-compat-libs \
    libxcb \
    libxkbcommon

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

# ── Portal shim: chkconfig compatibility ─────────────────────────────────────
# Some Portal helper scripts call 'chkconfig'. Symlink to systemctl on AL2023.
if [[ ! -e /sbin/chkconfig ]]; then
    ln -sf /usr/bin/systemctl /sbin/chkconfig
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

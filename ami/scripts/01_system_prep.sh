#!/usr/bin/env bash
# 01_system_prep.sh
# System update, build dependencies, and disable Nouveau GPU driver.
# Must be run as root on a fresh Ubuntu 22.04 instance.

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1

echo "==> [01] System prep started at $(date)"

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get upgrade -y
apt-get install -y \
    build-essential \
    dkms \
    "linux-headers-$(uname -r)" \
    curl \
    wget \
    unzip \
    jq \
    python3-pip \
    awscli \
    ca-certificates \
    gnupg \
    lsb-release \
    libxkbcommon0 \
    libxkbcommon-x11-0 \
    libxcb-cursor0 \
    libxcb-icccm4 \
    libxcb-image0 \
    libxcb-keysyms1 \
    libxcb-render-util0 \
    libxcb-shape0 \
    libxcb-randr0 \
    libxcb-xfixes0 \
    libxcb-xinerama0 \
    libxss1

# Disable Nouveau (conflicts with NVIDIA data center driver)
cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

update-initramfs -u

echo "==> [01] System prep complete"

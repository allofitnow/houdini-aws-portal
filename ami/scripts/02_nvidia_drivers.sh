#!/usr/bin/env bash
# 02_nvidia_drivers.sh
# Install NVIDIA data center driver (535+) for L40S on Ubuntu 22.04.
# Requires a reboot after 01_system_prep.sh (Nouveau must be disabled first).

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1
set -euo pipefail

echo "==>"

DRIVER_VERSION="535-server"

# Use Ubuntu repos' -server driver (DKMS-built for HWE kernels like 6.8.x-aws).
# The CUDA repo's nvidia-driver-535 conflicts with kernel 6.8 on Jammy.
apt-get update -y
apt-get install -y \
    nvidia-driver-${DRIVER_VERSION} \
    nvidia-utils-${DRIVER_VERSION}

# Verify driver is loadable (won't show GPU without reboot, but package must install cleanly)
dpkg -l | grep -E "nvidia-driver-${DRIVER_VERSION}" | grep -q "^ii" || {
    echo "ERROR: NVIDIA driver package not installed correctly"
    exit 1
}

# Persistence daemon for reduced latency on first GPU call
# May fail if already enabled or not installed — non-fatal
systemctl enable nvidia-persistenced || true

echo "==> [02] NVIDIA driver install complete — reboot required before nvidia-smi will work"

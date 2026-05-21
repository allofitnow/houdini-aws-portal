#!/usr/bin/env bash
# 02_nvidia_drivers.sh
# Install NVIDIA data center driver (535+) for L40S on Ubuntu 22.04.
# Requires a reboot after 01_system_prep.sh (Nouveau must be disabled first).

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1

echo "==> [02] NVIDIA driver install started at $(date)"

DRIVER_VERSION="535"

# Add NVIDIA apt repository
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/3bf863cc.pub \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/nvidia-archive-keyring.gpg] \
https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/ /" \
    > /etc/apt/sources.list.d/nvidia-cuda.list

apt-get update -y
apt-get install -y \
    nvidia-driver-${DRIVER_VERSION} \
    nvidia-utils-${DRIVER_VERSION} \
    cuda-drivers

# Verify driver is loadable (won't show GPU without reboot, but package must install cleanly)
dpkg -l | grep -E "nvidia-driver-${DRIVER_VERSION}" | grep -q "^ii" || {
    echo "ERROR: NVIDIA driver package not installed correctly"
    exit 1
}

# Persistence daemon for reduced latency on first GPU call
systemctl enable nvidia-persistenced || true

echo "==> [02] NVIDIA driver install complete — reboot required before nvidia-smi will work"

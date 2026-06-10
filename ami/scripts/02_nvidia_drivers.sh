#!/usr/bin/env bash
# 02_nvidia_drivers.sh
# Download and install NVIDIA R550 datacenter driver from S3 for AL2023 + L40S.
# Preconditions: 01_system_prep.sh completed, S3_BUCKET and AWS_REGION set,
# nouveau blacklisted, reboot recommended before nvidia-smi will function.

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1
set -euo pipefail

echo "==> [02] NVIDIA driver install started at $(date)"

DRIVER_FILE="NVIDIA-Linux-x86_64-550.163.01.run"
DRIVER_PATH="/tmp/${DRIVER_FILE}"

# ── Idempotency: skip if nvidia kernel module already loaded ──
if command -v nvidia-smi &>/dev/null; then
    echo "==> [02] nvidia-smi already present — skipping install"
    exit 0
fi

# ── Verify required environment variables ──
if [[ -z "${S3_BUCKET:-}" ]]; then
    echo "ERROR: S3_BUCKET environment variable not set"
    exit 1
fi
if [[ -z "${AWS_REGION:-}" ]]; then
    echo "ERROR: AWS_REGION environment variable not set"
    exit 1
fi

# ── Install build dependencies for NVIDIA kernel module ──
echo "==> [02] Installing kernel headers and build tools"
KERNEL_VER="$(uname -r)"
dnf install -y \
    gcc \
    make \
    "kernel-devel-${KERNEL_VER}" \
    elfutils-libelf-devel

# ── Blacklist nouveau (AL2023 uses dracut) ──
NOUVEAU_CONF="/etc/modprobe.d/blacklist-nouveau.conf"
if [[ -f "${NOUVEAU_CONF}" ]]; then
    echo "==> [02] nouveau blacklist already exists — verifying content"
    if ! grep -q "^blacklist nouveau$" "${NOUVEAU_CONF}" \
       || ! grep -q "^options nouveau modeset=0$" "${NOUVEAU_CONF}"; then
        echo "WARN: ${NOUVEAU_CONF} exists but content unexpected — overwriting"
        cat > "${NOUVEAU_CONF}" << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
        dracut --force
    fi
else
    echo "==> [02] Creating nouveau blacklist and rebuilding initramfs"
    cat > "${NOUVEAU_CONF}" << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
    dracut --force
fi

# ── Download NVIDIA driver from S3 ──
echo "==> [02] Downloading ${DRIVER_FILE} from s3://${S3_BUCKET}/installers/"
aws s3 cp "s3://${S3_BUCKET}/installers/${DRIVER_FILE}" "${DRIVER_PATH}" \
    --region "${AWS_REGION}"

if [[ ! -f "${DRIVER_PATH}" ]]; then
    echo "ERROR: Driver file not found after download: ${DRIVER_PATH}"
    exit 1
fi

# ── Load DRM kernel modules required by nvidia.ko on AL2023 ──
echo "==> [02] Loading DRM kernel modules"
modprobe drm 2>/dev/null || echo "WARN: modprobe drm failed (may be built-in)"
modprobe drm_kms_helper 2>/dev/null || echo "WARN: modprobe drm_kms_helper failed (may be built-in)"

# ── Silent unattended install ──
echo "==> [02] Running NVIDIA driver silent install"
sh "${DRIVER_PATH}" --silent --no-cc-version-check

# ── Verify install ──
if ! command -v nvidia-smi &>/dev/null; then
    echo "ERROR: nvidia-smi not found after install"
    exit 1
fi
echo "==> [02] nvidia-smi binary verified at $(command -v nvidia-smi)"

# ── Enable nvidia-persistenced for reduced latency on first GPU call ──
# Non-fatal — may fail if service not available in this driver version
if systemctl cat nvidia-persistenced &>/dev/null; then
    systemctl enable nvidia-persistenced || {
        RET=$?
        echo "WARN: nvidia-persistenced enable failed (exit ${RET}) — non-fatal"
    }
else
    echo "==> [02] nvidia-persistenced service not found — skipping"
fi

# ── Cleanup ──
rm -f "${DRIVER_PATH}"

echo "==> [02] NVIDIA driver install complete — reboot required before nvidia-smi will work"

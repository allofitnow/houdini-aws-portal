#!/usr/bin/env bash
# setup_desktop.sh
# Provision a minimal GNOME desktop + Amazon DCV on a Deadline Spot Worker.
#
# Runs entirely over SSM — no console/interactive access needed.
# Designed to be called standalone or from launch_ready_spot_worker.sh
# when INSTALL_DESKTOP=true.
#
# Usage (standalone):
#   bash aws/setup_desktop.sh <instance-id> [region]
#
# Usage (integrated into launch):
#   INSTALL_DESKTOP=true bash aws/launch_ready_spot_worker.sh
#
# Optional env vars:
#   DCV_PASSWORD   Password for ubuntu user (default: Someofitlater12!)
#   DCV_PORT       DCV listen port (default: 8443)
#   REGION         AWS region (default: us-east-1)
#
# After setup, connect with the Amazon DCV client:
#   Download: https://www.amazondcv.com/latest.html
#   Host:     <zerotier-ip>:8443   (no public port needed via ZeroTier)
#   User:     ubuntu / <DCV_PASSWORD>

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
INSTANCE_ID="${1:-${INSTANCE_ID:-}}"
REGION="${2:-${REGION:-us-east-1}}"
DCV_PORT="${DCV_PORT:-8443}"
DCV_USER="ubuntu"

# Generate a strong random password if not provided
if [[ -z "${DCV_PASSWORD:-}" ]]; then
    DCV_PASSWORD="Someofitlater12!"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
# shellcheck source=/dev/null
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

if [[ -z "$INSTANCE_ID" ]]; then
    echo "Usage: $0 <instance-id> [region]" >&2
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required." >&2; exit 1
fi

# ---------------------------------------------------------------------------
# SSM helper — longer poll timeout for package installs
# ---------------------------------------------------------------------------
# ssm_run <instance-id> [--timeout <seconds>] <cmd1> [<cmd2> ...]
#   Each remaining argument is one shell command executed in sequence.
ssm_run() {
    local instance_id="$1"; shift
    local exec_timeout=1800  # 30 min default
    if [[ "${1:-}" == "--timeout" ]]; then
        exec_timeout="$2"; shift 2
    fi

    local tmp; tmp=$(mktemp)
    printf '%s\n' "$@" | jq -R . | jq -s \
        --arg iid "$instance_id" \
        --arg to "$exec_timeout" \
        '{DocumentName:"AWS-RunShellScript",InstanceIds:[$iid],
          Parameters:{commands:.,executionTimeout:[$to]}}' \
        > "$tmp"

    local cid
    cid=$(aws ssm send-command --region "$REGION" \
        --cli-input-json "file://$tmp" \
        --query Command.CommandId --output text)
    rm -f "$tmp"
    printf '  [ssm %s] ' "$cid" >&2

    local max_polls=$(( (exec_timeout + 120) / 8 ))
    local st
    for _ in $(seq 1 "$max_polls"); do
        st=$(aws ssm get-command-invocation \
            --region "$REGION" --command-id "$cid" \
            --instance-id "$instance_id" \
            --query Status --output text 2>/dev/null || true)
        case "$st" in
            Success|Failed|Cancelled|TimedOut|Cancelling) break ;;
        esac
        printf '.' >&2; sleep 8
    done
    printf ' %s\n' "$st" >&2

    aws ssm get-command-invocation \
        --region "$REGION" --command-id "$cid" \
        --instance-id "$instance_id" \
        --query '[Status,StandardOutputContent,StandardErrorContent]' \
        --output text
}

wait_for_ssm() {
    echo "Waiting for SSM to come online for ${INSTANCE_ID}..."
    for _ in {1..72}; do
        local st
        st=$(aws ssm describe-instance-information \
            --region "$REGION" \
            --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
            --query 'InstanceInformationList[0].PingStatus' \
            --output text 2>/dev/null || true)
        if [[ "$st" == "Online" ]]; then
            echo "SSM online."; return 0
        fi
        sleep 10
    done
    echo "ERROR: Timed out waiting for SSM." >&2; exit 1
}

# ---------------------------------------------------------------------------
# Ensure the instance IAM role can read the DCV license S3 bucket (free on EC2)
# ---------------------------------------------------------------------------
ensure_dcv_iam_policy() {
    echo "Checking DCV license IAM policy..."
    local profile_arn role_name
    profile_arn=$(aws ec2 describe-instances --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
        --output text 2>/dev/null || true)

    if [[ -z "$profile_arn" || "$profile_arn" == "None" ]]; then
        echo "  WARNING: No IAM profile found — skipping DCV license policy." >&2
        return 0
    fi

    local profile_name; profile_name=$(basename "$profile_arn")
    role_name=$(aws iam get-instance-profile \
        --instance-profile-name "$profile_name" \
        --query 'InstanceProfile.Roles[0].RoleName' \
        --output text 2>/dev/null || true)

    if [[ -z "$role_name" || "$role_name" == "None" ]]; then
        echo "  WARNING: Could not resolve IAM role name." >&2
        return 0
    fi

    # Idempotent: skip if already present
    if aws iam list-role-policies --role-name "$role_name" \
            --output text 2>/dev/null | grep -q dcv-license-read; then
        echo "  DCV license policy already attached to ${role_name}."
        return 0
    fi

    echo "  Attaching DCV license read policy to ${role_name}..."
    aws iam put-role-policy \
        --role-name "$role_name" \
        --policy-name dcv-license-read \
        --policy-document "{
            \"Version\": \"2012-10-17\",
            \"Statement\": [{
                \"Effect\": \"Allow\",
                \"Action\": \"s3:GetObject\",
                \"Resource\": \"arn:aws:s3:::dcv-license.${REGION}/*\"
            }]
        }"
    echo "  Policy attached."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo " GNOME + Amazon DCV setup: ${INSTANCE_ID} (${REGION})"
echo "================================================================"

ensure_dcv_iam_policy

# ── Step 1: Install minimal GNOME desktop ────────────────────────────────
echo ""
echo "=== Step 1/6: Installing GNOME desktop (may take 10-15 min) ==="
ssm_run "$INSTANCE_ID" --timeout 1800 \
    "export DEBIAN_FRONTEND=noninteractive" \
    "apt-get update -q" \
    "apt-get install -y --no-install-recommends ubuntu-desktop-minimal gdm3 mesa-utils pulseaudio" \
    "systemctl set-default graphical.target" \
    "echo 'GNOME install done'"

# Disable Wayland (DCV requires X11) and configure auto-login
ssm_run "$INSTANCE_ID" \
    "sed -i 's|#WaylandEnable=false|WaylandEnable=false|g' /etc/gdm3/custom.conf" \
    "grep -q 'WaylandEnable=false' /etc/gdm3/custom.conf || echo 'WaylandEnable=false' >> /etc/gdm3/custom.conf" \
    "grep -q 'AutomaticLoginEnable' /etc/gdm3/custom.conf && \
        sed -i 's|#\?AutomaticLoginEnable.*|AutomaticLoginEnable=true|' /etc/gdm3/custom.conf || \
        sed -i '/\[daemon\]/a AutomaticLoginEnable=true\nAutomaticLogin=ubuntu' /etc/gdm3/custom.conf" \
    "echo 'gdm3 configured'"

# ── Step 2: Configure NVIDIA X server for DCV ─────────────────────────────
echo ""
echo "=== Step 2/6: Configuring NVIDIA X for DCV ==="
ssm_run "$INSTANCE_ID" \
    "rm -f /etc/X11/XF86Config*" \
    "nvidia-xconfig --preserve-busid --enable-all-gpus 2>/dev/null || echo 'nvidia-xconfig not available (ok for virtual sessions)'" \
    "echo 'options nvidia NVreg_EnableGpuFirmware=0' | tee /etc/modprobe.d/nvidia-dcv.conf" \
    "echo 'NVIDIA xorg configured'"

# ── Step 3: Download and install Amazon DCV 2025.x ────────────────────────
echo ""
echo "=== Step 3/6: Installing Amazon DCV server (may take 5-10 min) ==="
ssm_run "$INSTANCE_ID" --timeout 1200 \
    "cd /tmp" \
    "wget -q https://d1uj6qtbmh3dt5.cloudfront.net/NICE-GPG-KEY -O /tmp/NICE-GPG-KEY" \
    "gpg --import /tmp/NICE-GPG-KEY 2>/dev/null || true" \
    "wget -q https://d1uj6qtbmh3dt5.cloudfront.net/nice-dcv-ubuntu2204-x86_64.tgz -O /tmp/dcv.tgz" \
    "tar -xzf /tmp/dcv.tgz -C /tmp" \
    "ls /tmp/nice-dcv-*-ubuntu2204-x86_64/" \
    "DEBIAN_FRONTEND=noninteractive apt-get install -y \
        /tmp/nice-dcv-*-ubuntu2204-x86_64/nice-dcv-server_*.deb \
        /tmp/nice-dcv-*-ubuntu2204-x86_64/nice-xdcv_*.deb \
        /tmp/nice-dcv-*-ubuntu2204-x86_64/nice-dcv-gl_*.deb \
        /tmp/nice-dcv-*-ubuntu2204-x86_64/nice-dcv-web-viewer_*.deb" \
    "usermod -aG video dcv" \
    "rm -rf /tmp/dcv.tgz /tmp/nice-dcv-*-ubuntu2204-x86_64" \
    "echo 'DCV install done'"

# ── Step 4: Configure DCV and set login password ──────────────────────────
echo ""
echo "=== Step 4/6: Configuring DCV ==="
# Write dcv.conf via python3 to safely embed multi-line content
ssm_run "$INSTANCE_ID" \
    "python3 -c \"
import os
content = '''[license]

[log]
level = INFO

[session-management]
create-session = true

[session-management/automatic-console-session]
owner = ubuntu

[display]
target-fps = 30
enable-gl-in-virtual-sessions = always-on

[connectivity]
enable-quic-frontend = true
quic-listen-endpoints = ['0.0.0.0:${DCV_PORT}', '[::]:${DCV_PORT}']
web-listen-endpoints = ['0.0.0.0:${DCV_PORT}', '[::]:${DCV_PORT}']

[security]
authentication = system
'''
open('/etc/dcv/dcv.conf','w').write(content)
print('dcv.conf written')
\"" \
    "echo '${DCV_USER}:${DCV_PASSWORD}' | chpasswd" \
    "systemctl enable dcvserver" \
    "echo 'DCV configured'"

# ── Step 4b: Enable SSH password authentication ─────────────────────────────
echo ""
echo "=== Step 4b/6: Enabling SSH password login ==="
ssm_run "$INSTANCE_ID" \
    "sed -i 's|^#\?PasswordAuthentication.*|PasswordAuthentication yes|' /etc/ssh/sshd_config" \
    "sed -i 's|^#\?KbdInteractiveAuthentication.*|KbdInteractiveAuthentication yes|' /etc/ssh/sshd_config" \
    "grep -q 'PasswordAuthentication yes' /etc/ssh/sshd_config && echo OK || echo MISSING" \
    "systemctl restart ssh" \
    "echo 'SSH password auth enabled'"

# ── Step 5: Reboot to apply X/GPU config ─────────────────────────────────
echo ""
echo "=== Step 5/6: Rebooting to apply GPU/X configuration ==="
# Fire-and-forget reboot (SSM connection will drop)
aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["sleep 2 && reboot"]' \
    --output text --query Command.CommandId >/dev/null 2>&1 || true
echo "Reboot triggered. Waiting 40s before polling..."
sleep 40
wait_for_ssm

# ── Step 6: Verify DCV is running ─────────────────────────────────────────
echo ""
echo "=== Step 6/6: Verifying DCV server ==="
ssm_run "$INSTANCE_ID" \
    "systemctl start dcvserver || true" \
    "sleep 5" \
    "systemctl is-active dcvserver" \
    "dcv list-sessions 2>/dev/null || true" \
    "nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null || true"

# ── Done ──────────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo " Amazon DCV ready on ${INSTANCE_ID}"
echo ""
echo "   DCV client:  <zerotier-ip>:${DCV_PORT}"
echo "   Browser:     https://<zerotier-ip>:${DCV_PORT}"
echo "   User:        ${DCV_USER}"
echo "   Password:    ${DCV_PASSWORD}"
echo ""
echo "   Download DCV client:"
echo "   https://www.amazondcv.com/latest.html"
echo "================================================================"

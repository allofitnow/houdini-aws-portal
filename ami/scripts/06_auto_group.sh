#!/usr/bin/env bash
# 06_auto_group.sh
# Creates a systemd service that:
#   1. Sets HostMachineIPAddressOverride to the ZeroTier IP (for RCS log access)
#   2. Auto-assigns the worker to the correct Deadline Group based on AWS region
#
# Workers in us-east-1 → group "aws-spot-east"
# Workers elsewhere    → group "aws-spot"
#
# The IP override is critical: without it, the RCS tries to connect back to the
# worker's EC2 private IP (172.31.x.x) for remote log access, which is
# unreachable from the on-prem network. Setting it to the ZeroTier IP
# (10.147.x.x) lets the RCS route through the overlay.

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1
set -euo pipefail

echo "==> [06] Auto-group-assign service setup started at $(date)"

cat > /usr/local/sbin/deadline-auto-group.sh << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# Determine group based on region
AWS_REGION="${AWS_REGION:-us-west-2}"
if [ "$AWS_REGION" = "us-east-1" ]; then
    GROUP="aws-spot-east"
else
    GROUP="aws-spot"
fi

HOSTNAME=$(hostname)
echo "[auto-group] Hostname: $HOSTNAME"

# ── Set HostMachineIPAddressOverride to ZeroTier IP ─────────────────────────
# The RCS needs this to connect back to the worker for remote log access.
# Without it, the RCS tries the EC2 private IP (172.31.x.x) which is
# unreachable from the on-prem network.
ZT_NETWORK="d3ecf5726d14ac76"
ZT_IP=""
for i in $(seq 1 30); do
    ZT_IP=$(zerotier-cli listnetworks 2>/dev/null | awk '/OK/{print $9}' | sed 's|/.*||')
    if [[ -n "$ZT_IP" ]]; then
        break
    fi
    echo "[auto-group] Waiting for ZeroTier IP (attempt $i/30)..."
    sleep 5
done

if [[ -n "$ZT_IP" ]]; then
    echo "[auto-group] ZeroTier IP: $ZT_IP"
    for j in $(seq 1 10); do
        if /usr/local/bin/deadlinecommand SetSlaveSetting "$HOSTNAME" HostMachineIPAddressOverride "$ZT_IP" 2>/dev/null; then
            echo "[auto-group] Set HostMachineIPAddressOverride=$ZT_IP"
            break
        fi
        echo "[auto-group] SetSlaveSetting attempt $j failed, retrying in 10s..."
        sleep 10
    done
else
    echo "[auto-group] WARNING: Could not determine ZeroTier IP after 30 attempts"
fi

# ── Assign to Deadline Group ────────────────────────────────────────────────
for i in $(seq 1 20); do
    if /usr/local/bin/deadlinecommand SetGroupsForSlave "$HOSTNAME" "$GROUP" 2>/dev/null; then
        echo "[auto-group] Successfully assigned to $GROUP"
        exit 0
    fi
    echo "[auto-group] Attempt $i failed, retrying in 15s..."
    sleep 15
done

echo "[auto-group] WARNING: Could not assign group after 20 attempts"
exit 1
SCRIPT

chmod 700 /usr/local/sbin/deadline-auto-group.sh

cat > /etc/systemd/system/deadline-auto-group.service << 'UNIT'
[Unit]
Description=Auto-assign worker to Deadline Group based on AWS region
After=deadline10launcher.service network-online.target
Wants=deadline10launcher.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/deadline-auto-group.sh
RemainAfterExit=yes
# Delay to let launcher register with RCS first
ExecStartPre=/bin/sleep 30

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable deadline-auto-group.service

echo "==> [06] Auto-group-assign service setup complete"

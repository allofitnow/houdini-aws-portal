#!/usr/bin/env bash
# hotfix_instance.sh — Apply AMI build fixes to a running Portal EC2 instance.
# Usage: ./aws/hotfix_instance.sh <instance-id>
#
# This script applies fixes that were discovered after the last AMI build,
# so you can test without rebuilding the AMI.
#
# Prerequisites:
#   - Instance must be running and SSM-accessible
#   - AWS CLI configured with appropriate credentials
#
# Fixes applied:
#   1. Create deadline10launcher.service systemd unit (AL2023 fix)
#   2. Restart the launcher (Portal user-data will have already configured deadline.ini)
#   3. Verify launcher is running and connected
#
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <instance-id>"
    echo "  e.g. $0 i-0c5886afd3f7145a6"
    exit 1
fi

INSTANCE_ID="$1"
REGION="${AWS_REGION:-us-west-2}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

run_ssm() {
    local description="$1"
    shift
    local cmd_id
    cmd_id=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name AWS-RunShellScript \
        --parameters "commands=$*" \
        --timeout-seconds 60 \
        --query 'Command.CommandId' \
        --output text \
        --region "$REGION" 2>&1)
    
    if [[ "$cmd_id" == *"error"* ]] || [[ "$cmd_id" == *"Error"* ]]; then
        echo "ERROR: SSM send-command failed: $cmd_id"
        return 1
    fi

    sleep 10

    local status output
    status=$(aws ssm get-command-invocation \
        --command-id "$cmd_id" \
        --instance-id "$INSTANCE_ID" \
        --query 'Status' \
        --output text \
        --region "$REGION" 2>&1)
    output=$(aws ssm get-command-invocation \
        --command-id "$cmd_id" \
        --instance-id "$INSTANCE_ID" \
        --query 'StandardOutputContent' \
        --output text \
        --region "$REGION" 2>&1)

    if [[ "$status" != "Success" ]]; then
        local err
        err=$(aws ssm get-command-invocation \
            --command-id "$cmd_id" \
            --instance-id "$INSTANCE_ID" \
            --query 'StandardErrorContent' \
            --output text \
            --region "$REGION" 2>&1)
        echo "ERROR: $description failed (status=$status)"
        echo "STDOUT: $output"
        echo "STDERR: $err"
        return 1
    fi

    echo "$output"
    return 0
}

# ── Pre-flight checks ────────────────────────────────────────────────────────
log "Checking instance $INSTANCE_ID state..."
STATE=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[].Instances[].State.Name' \
    --output text \
    --region "$REGION" 2>&1)

if [[ "$STATE" != "running" ]]; then
    echo "ERROR: Instance is $STATE, must be running"
    exit 1
fi

log "Checking SSM connectivity..."
SSM_STATUS=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text \
    --region "$REGION" 2>&1)

if [[ "$SSM_STATUS" != "Online" ]]; then
    echo "ERROR: Instance is not online via SSM (status=$SSM_STATUS)"
    exit 1
fi

log "Instance is running and SSM-online ✓"

# ── Fix 1: Create deadline10launcher.service systemd unit ────────────────────
log "Fix 1: Creating deadline10launcher.service systemd unit..."

# Base64-encode the service unit to avoid heredoc escaping issues
SERVICE_UNIT=$(cat <<'SVCEOF' | base64 -w0
[Unit]
Description=Deadline 10 Launcher
After=houdini-ubl.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/Thinkbox/Deadline10/bin/deadlinelauncher
Restart=on-failure
RestartSec=10
Environment=HOME=/root

[Install]
WantedBy=multi-user.target
SVCEOF
)

run_ssm "Create service unit" \
    "[\"echo $SERVICE_UNIT | base64 -d > /etc/systemd/system/deadline10launcher.service\", \"systemctl daemon-reload\"]" \
    || exit 1

log "Service unit created ✓"

# ── Fix 2: Enable and start the launcher ─────────────────────────────────────
log "Fix 2: Enabling and starting deadline10launcher..."

run_ssm "Enable+start launcher" \
    "[\"systemctl enable deadline10launcher.service\", \"systemctl start deadline10launcher.service\", \"sleep 5\", \"systemctl status deadline10launcher.service --no-pager\"]" \
    || exit 1

log "Launcher started ✓"

# ── Fix 3: Verify connection ─────────────────────────────────────────────────
log "Fix 3: Verifying launcher logs (last 10 lines)..."

run_ssm "Check launcher logs" \
    "[\"journalctl -u deadline10launcher --no-pager -n 10\"]" \
    || true

log ""
log "========================================="
log "Hotfix applied successfully!"
log "========================================="
log ""
log "The launcher should now be connecting to the Portal proxy."
log "Check Deadline Monitor for the new worker."
log ""
log "NOTE: The Portal user-data should have already configured deadline.ini"
log "      with ProxyRoot=127.0.0.1:8080 and the Gateway certs."
log "      If the worker doesn't appear, check Portal Link service on the"
log "      Deadline host and ensure the VPC/security groups allow connectivity."
log ""
log "IMPORTANT: This fix is temporary. For permanent fix, rebuild the AMI"
log "           with the updated 05_deadline_worker.sh (commit 02fb58b)."

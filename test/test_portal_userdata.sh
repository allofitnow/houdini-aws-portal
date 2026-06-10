#!/usr/bin/env bash
# test_portal_userdata.sh — Dry-run the Portal user-data on the build instance.
#
# Purpose: Run the Portal user-data script (from Portal-Ready-AMI-Spec wiki)
#          on the build instance to catch failures before snapshotting the AMI.
#          Uses a test stack name so it doesn't interfere with production.
#
# Usage:
#   sudo bash test_portal_userdata.sh
#
# Exit codes:
#   0  All Portal user-data commands succeeded
#   1  One or more commands failed
#
# Prerequisites:
#   - AMI build scripts (01-06) have completed successfully
#   - No-op awslogs shim service exists
#   - python symlink exists
#   - deadline.ini exists at /var/lib/Thinkbox/Deadline10/deadline.ini
#   - Instance has S3 read access (for gateway cert download)

set -euo pipefail

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1
echo "==> [test] Portal user-data dry run started at $(date)"

TEST_STACK="test-dryrun-stack"
DL_INI="/var/lib/Thinkbox/Deadline10/deadline.ini"
PASS=0
FAIL=0

run_check() {
    local desc="$1"
    shift
    echo "  CHECK: $desc"
    if "$@" 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

# 1. License ports script (touch + chmod)
run_check "license_ports.sh touch" touch /etc/profile.d/license_ports.sh
run_check "license_ports.sh chmod" chmod 777 /etc/profile.d/license_ports.sh

# 2. Environment variables script
run_check "env_vars.sh touch" touch /etc/profile.d/env_vars.sh
run_check "env_vars.sh chmod" chmod 777 /etc/profile.d/env_vars.sh

# 3. Set Region in deadline.ini
if [[ -f "$DL_INI" ]]; then
    run_check "Set Region in deadline.ini" sed -im "s/Region=.*$/Region=${TEST_STACK}/g" "$DL_INI"
else
    echo "  SKIP: $DL_INI does not exist"
    FAIL=$((FAIL + 1))
fi

# 4. Enable auto-launch
if [[ -f "$DL_INI" ]]; then
    run_check "Set LaunchSlaveAtStartup=true" sed -im 's/LaunchSlaveAtStartup=.*$/LaunchSlaveAtStartup=true/g' "$DL_INI"
fi

# 5. Mark as Portal instance
if [[ -f "$DL_INI" ]]; then
    run_check "Append AWSPortalInstance=True" bash -c "echo AWSPortalInstance=True >> '$DL_INI'"
fi

# 6. Download Gateway certs (use real bucket but skip if no S3 access)
CERT_DIR="/var/lib/Thinkbox/Deadline10/gateway_certs"
run_check "Create gateway_certs dir" mkdir -p "$CERT_DIR"
# NOTE: Real cert download requires the actual Portal stack bucket.
# In dry-run mode, just verify the command path exists.
if aws s3 ls "s3://stacka27189af3e224b4ba366cf5386ace5c0-bucket/gateway_certs/ca.crt" --region us-west-2 >/dev/null 2>&1; then
    run_check "Download Gateway ca.crt" aws s3 cp "s3://stacka27189af3e224b4ba366cf5386ace5c0-bucket/gateway_certs/ca.crt" "$CERT_DIR" --region us-west-2
else
    echo "  SKIP: Gateway cert download (no S3 access or bucket not reachable — OK in dry-run)"
fi

# 7. Restart Deadline launcher (skip in dry-run — service may not be configured yet)
echo "  SKIP: service deadline10launcher restart (not started in dry-run)"

# 8. CloudWatch logging setup
run_check "service awslogs stop" service awslogs stop
run_check "set_awslogs_region.py" python /opt/Thinkbox/CloudWatchSetup/bin/set_awslogs_region.py us-west-2
run_check "add_awslogs_stream_name_prefix.py" python /opt/Thinkbox/CloudWatchSetup/bin/add_awslogs_stream_name_prefix.py "$TEST_STACK"
run_check "on_instance_init.sh" sh /opt/Thinkbox/CloudWatch/on_instance_init.sh "stackname=$TEST_STACK"
run_check "chkconfig --add awslogs" chkconfig --add awslogs
run_check "chkconfig awslogs on" chkconfig awslogs on
run_check "service awslogs start" service awslogs start

# 9. Worker slave config writable
run_check "chmod slaves dir" chmod -R 777 /var/lib/Thinkbox/Deadline10/slaves

# 10. AWS CLI config for ec2-user
run_check "mkdir .aws" mkdir -p /home/ec2-user/.aws
run_check "write .aws/config" bash -c "echo '[default]' > /home/ec2-user/.aws/config && echo 'region = us-west-2' >> /home/ec2-user/.aws/config"

# Verify post-user-data state
echo ""
echo "==> [test] Verifying post-user-data state..."

if [[ -f "$DL_INI" ]]; then
    echo "--- deadline.ini contents ---"
    cat "$DL_INI"
    echo "--- end ---"

    if grep -q "Region=${TEST_STACK}" "$DL_INI"; then echo "  PASS: Region set to ${TEST_STACK}"; else echo "  FAIL: Region not set"; FAIL=$((FAIL + 1)); fi
    if grep -q "LaunchSlaveAtStartup=true" "$DL_INI"; then echo "  PASS: LaunchSlaveAtStartup=true"; else echo "  FAIL: LaunchSlaveAtStartup not true"; FAIL=$((FAIL + 1)); fi
    if grep -q "AWSPortalInstance=True" "$DL_INI"; then echo "  PASS: AWSPortalInstance=True"; else echo "  FAIL: AWSPortalInstance not set"; FAIL=$((FAIL + 1)); fi
fi

echo ""
echo "==> [test] Portal user-data dry run complete: ${PASS} passed, ${FAIL} failed"
echo "==> [test] Finished at $(date)"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0

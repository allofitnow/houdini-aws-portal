#!/usr/bin/env bash
# cleanup_orphaned_sfrs.sh — Cancel stale AWS Spot Fleet Requests.
#
# Purpose: Deadline's Spot Event Plugin (SEP) can leave old Spot Fleet Requests
#          behind after restarts, reconfigurations, or failed launches. These
#          orphaned SFRs continue to exist in AWS and clutter monitoring. This
#          script cancels SFRs that are not the currently active SFR for any
#          configured SEP group.
#
# Prerequisites:
#   - AWS CLI configured with EC2 permissions
#   - Optional: deadlinecommand on PATH if --active-from-sep is used
#
# Usage:
#   ./cleanup_orphaned_sfrs.sh [--region us-east-1] [--dry-run]
#   ./cleanup_orphaned_sfrs.sh --active-from-sep [--dry-run]
#
# Exit codes:
#   0  Cleanup completed (or nothing to do)
#   1  AWS CLI or required permission missing
#   2  User cancelled interactive prompt

set -euo pipefail

# --- Defaults ---
REGION=""
DRY_RUN=false
ACTIVE_FROM_SEP=false
FORCE=false

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)       REGION="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --active-from-sep) ACTIVE_FROM_SEP=true; shift ;;
        --force)        FORCE=true; shift ;;
        --help|-h)
            head -25 "$0" | grep '^#'
            exit 0
            ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# --- Validate prerequisites ---
if ! command -v aws &>/dev/null; then
    echo "FATAL: aws CLI not found on PATH" >&2
    exit 1
fi

# --- Determine active SFR IDs ---
ACTIVE_SFR_IDS=""
if [[ "$ACTIVE_FROM_SEP" == true ]]; then
    if ! command -v deadlinecommand &>/dev/null; then
        echo "FATAL: --active-from-sep requires deadlinecommand on PATH" >&2
        exit 1
    fi

    # Extract SFR IDs from the live Spot Event Plugin config.
    ACTIVE_SFR_IDS=$(python3 - <<'PY'
import subprocess, json, re, sys
DL = '/mnt/c/Program Files/Thinkbox/Deadline10/bin/deadlinecommand.exe'
script = '''
from Deadline.Scripting import RepositoryUtils
cfg = RepositoryUtils.GetEventPluginConfig("Spot")
print(cfg.GetConfigEntry("Config"))
'''
with open('/tmp/dl_sep_cfg.py','w') as f: f.write(script)
wp = subprocess.check_output(['wslpath','-w','/tmp/dl_sep_cfg.py']).decode().strip()
r = subprocess.run([DL,'ExecuteScript',wp], capture_output=True, text=True)
if r.returncode != 0:
    print(r.stderr, file=sys.stderr)
    sys.exit(1)
cfg = json.loads(r.stdout.strip())
ids = set()
for region_block in cfg.get('regions', []):
    for group in region_block.get('group_configs', {}).values():
        sfr_id = group.get('SpotFleetRequestId')
        if sfr_id:
            ids.add(sfr_id)
print('\n'.join(ids))
PY
    ) || {
        echo "FATAL: Could not read active SFR IDs from SEP config" >&2
        exit 1
    }
fi

# --- Build AWS args ---
AWS_ARGS=()
if [[ -n "$REGION" ]]; then
    AWS_ARGS+=(--region "$REGION")
fi

# --- List cancellable SFRs ---
echo "==> Scanning Spot Fleet Requests..."
mapfile -t SFR_LINES < <(aws ec2 describe-spot-fleet-requests "${AWS_ARGS[@]}" --output json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('SpotFleetRequestConfigs', []):
    state = r.get('SpotFleetRequestState', '')
    if state in ('submitted', 'active', 'pending_fulfillment', 'modifying', 'cancelled_terminating'):
        print('%s|%s|%s' % (r.get('SpotFleetRequestId'), state, r.get('ActivityStatus', 'None')))
")

if [[ ${#SFR_LINES[@]} -eq 0 ]]; then
    echo "No active/pending Spot Fleet Requests found."
    exit 0
fi

# --- Filter out active SEP SFRs ---
TO_CANCEL=()
for line in "${SFR_LINES[@]}"; do
    IFS='|' read -r SFR_ID STATE ACTIVITY <<< "$line"

    if [[ "$ACTIVE_FROM_SEP" == true ]] && echo "$ACTIVE_SFR_IDS" | grep -qx "$SFR_ID"; then
        echo "KEEP  : $SFR_ID ($STATE / $ACTIVITY) — referenced by current SEP config"
        continue
    fi

    TO_CANCEL+=("$SFR_ID")
done

if [[ ${#TO_CANCEL[@]} -eq 0 ]]; then
    echo "No orphaned Spot Fleet Requests to cancel."
    exit 0
fi

echo ""
echo "Will cancel the following SFRs:"
for sfr in "${TO_CANCEL[@]}"; do
    echo "  - $sfr"
done

if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo "Dry run: no SFRs were cancelled."
    exit 0
fi

if [[ "$FORCE" != true ]]; then
    echo ""
    read -rp "Cancel these SFRs? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Cancelled by user."
        exit 2
    fi
fi

# --- Cancel SFRs ---
echo ""
FAILED=0
for sfr in "${TO_CANCEL[@]}"; do
    echo "Cancelling $sfr..."
    if aws ec2 cancel-spot-fleet-requests "${AWS_ARGS[@]}" --spot-fleet-request-ids "$sfr" --terminate-instances --output json >/dev/null 2>&1; then
        echo "  OK: $sfr"
    else
        echo "  FAIL: $sfr"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "==> Cancelled ${#TO_CANCEL[@]} SFR(s), $FAILED failure(s)."
exit $((FAILED > 0 ? 1 : 0))

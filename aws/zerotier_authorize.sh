#!/usr/bin/env bash
# zerotier_authorize.sh — Authorize (or deauthorize) a ZeroTier node on a network
# Usage:
#   ./zerotier_authorize.sh <node-id> [network-id]  — authorize
#   ./zerotier_authorize.sh --deauth <node-id> [network-id]  — deauthorize
#   ./zerotier_authorize.sh --list [network-id]  — list members
#
# Reads ZEROTIER_API_TOKEN from .env or environment.
# Defaults network to ZEROTIER_NETWORK env var or d3ecf5726d14ac76.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

# Load .env if present and token not already set
if [[ -z "${ZEROTIER_API_TOKEN:-}" && -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

if [[ -z "${ZEROTIER_API_TOKEN:-}" ]]; then
    echo "ERROR: ZEROTIER_API_TOKEN not set. Set it in .env or environment." >&2
    exit 1
fi

ZEROTIER_API="https://my.zerotier.com/api/v1"
NETWORK="${2:-${ZEROTIER_NETWORK:-d3ecf5726d14ac76}}"

curl_opts=(-s -H "Authorization: token $ZEROTIER_API_TOKEN")

case "${1:-}" in
    --list)
        echo "Members of network $NETWORK:"
        curl "${curl_opts[@]}" "$ZEROTIER_API/network/$NETWORK/member" \
            | python3 -c '
import json, sys
members = json.load(sys.stdin)
for m in members:
    auth = "AUTHORIZED" if m.get("config", {}).get("authorized") else "PENDING"
    name = m.get("name") or m.get("description") or "-"
    ips = ", ".join(m.get("config", {}).get("ipAssignments", [])) or "none"
    nid = m["nodeId"]
    print("  %-10s  %-12s  %-20s  IPs: %s" % (nid, auth, name, ips))
'
        ;;
    --deauth)
        NODE="$2"
        NETWORK="${3:-$NETWORK}"
        echo "Deauthorizing node $NODE on network $NETWORK..."
        curl "${curl_opts[@]}" -X POST \
            "$ZEROTIER_API/network/$NETWORK/member/$NODE" \
            -H "Content-Type: application/json" \
            -d '{"config":{"authorized":false}}' | python3 -c '
import json, sys
r = json.load(sys.stdin)
auth = r.get("config", {}).get("authorized", "?")
nid = r.get("nodeId", "?")
print("  Node %s authorized=%s" % (nid, auth))
'
        ;;
    --help|-h)
        echo "Usage: $0 [--list|--deauth] <node-id> [network-id]"
        echo "  No flags: authorize <node-id>"
        echo "  --list: show all members"
        echo "  --deauth <node-id>: revoke access"
        ;;
    *)
        NODE="$1"
        echo "Authorizing node $NODE on network $NETWORK..."
        curl "${curl_opts[@]}" -X POST \
            "$ZEROTIER_API/network/$NETWORK/member/$NODE" \
            -H "Content-Type: application/json" \
            -d '{"config":{"authorized":true}}' | python3 -c '
import json, sys
r = json.load(sys.stdin)
auth = r.get("config", {}).get("authorized", "?")
ips = ", ".join(r.get("config", {}).get("ipAssignments", [])) or "pending"
nid = r.get("nodeId", "?")
print("  Node %s authorized=%s  IPs: %s" % (nid, auth, ips))
'
        ;;
esac

#!/usr/bin/env bash
# 03_zerotier.sh
# Install ZeroTier client and configure a systemd service to auto-join,
# authorize, and assign an IP to the worker via the ZeroTier API using
# AWS Secrets Manager.
# Preconditions: IAM role must have secretsmanager:GetSecretValue access
# to "houdini/zerotier-api-token".

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1
set -euo pipefail

echo "==> [03] ZeroTier install started at $(date)"

# Network ID is set inside the embedded boot script below.
# Install ZeroTier via official script
if command -v zerotier-cli &>/dev/null; then
    echo "==> [03] ZeroTier already installed, skipping install"
else
    curl -s https://install.zerotier.com | bash
fi

# We do NOT join the network here. We let the boot script handle it.
# Create the auto-join boot script
cat > /usr/local/sbin/zerotier-auto-join.sh << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

ZT_NETWORK="d3ecf5726d14ac76"

# Nodes that must NEVER be purged and should be re-authorized if found
# unauthorized (RCS host, infrastructure nodes, etc.)
SKIP_NODES="e4d9033573"  # ATXRTX (RCS host)

AWS_REGION="${AWS_REGION:-us-west-2}"
MARKER="/var/lib/zerotier-one/.identity-regenerated"

echo "Starting ZeroTier auto-join for network $ZT_NETWORK..."

# ── 1. Force new identity on first boot to avoid AMI identity collision ──
if [[ ! -f "$MARKER" ]]; then
    echo "First boot detected — regenerating ZeroTier identity..."
    systemctl stop zerotier-one || true
    rm -f /var/lib/zerotier-one/identity.*
    systemctl start zerotier-one
    for i in $(seq 1 30); do
        zerotier-cli info >/dev/null 2>&1 && break
        sleep 2
    done
    touch "$MARKER"
    echo "Identity regenerated."
fi

# ── 2. Wait for daemon ──
until zerotier-cli info >/dev/null 2>&1; do
    echo "Waiting for zerotier daemon..."
    sleep 2
done

NODE_ID=$(zerotier-cli info | awk '{print $3}')
echo "Node ID is $NODE_ID. Joining network..."
zerotier-cli join "$ZT_NETWORK" || true  # may already be joined

# ── 3. Fetch API token from Secrets Manager ──
echo "Fetching ZeroTier API token..."
ZT_TOKEN=$(aws secretsmanager get-secret-value \
    --region "$AWS_REGION" \
    --secret-id "houdini/zerotier-api-token" \
    --query SecretString --output text 2>/dev/null || true)

if [[ -z "$ZT_TOKEN" || "$ZT_TOKEN" == "PENDING" ]]; then
    echo "ERROR: ZeroTier API token not found or PENDING. Cannot auto-authorize."
    exit 1
fi

# Export so the Python helper can access them (heredoc 'PYEOF' is quoted,
# so shell variables are NOT expanded inside it — must use os.environ)
export ZT_TOKEN ZT_NETWORK NODE_ID SKIP_NODES

# ── 4. Purge stale members, protect infra, authorize self, assign IP ──
python3 << 'PYEOF'
import json
import os
import subprocess
import time
import ipaddress

ZT_TOKEN   = os.environ['ZT_TOKEN']
ZT_NETWORK = os.environ['ZT_NETWORK']
NODE_ID    = os.environ['NODE_ID']
SKIP_NODES = set(os.environ.get('SKIP_NODES', '').split())

API_BASE = f"https://api.zerotier.com/api/v1/network/{ZT_NETWORK}"
STALE_MS = 3_600_000  # 1 hour — only purge members unseen this long


def curl_json(method, path, data=None):
    """Run a curl request and return (status_code, response_body)."""
    cmd = ["curl", "-s", "-w", "\n%{http_code}",
           "-X", method,
           "-H", f"Authorization: token {ZT_TOKEN}"]
    if data is not None:
        cmd += ["-H", "Content-Type: application/json", "-d", json.dumps(data)]
    cmd.append(f"{API_BASE}/{path}")
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    lines = r.stdout.rsplit("\n", 1)
    body = lines[0] if len(lines) == 2 else ""
    code = lines[-1].strip() if lines else "000"
    try:
        return code, json.loads(body) if body.strip() else {}
    except json.JSONDecodeError:
        return code, {}


# ── 4a. Get network IP pool ──
_, net = curl_json("GET", "")
pools = net.get("config", {}).get("ipAssignmentPools", [])
if pools:
    pool_start = int(ipaddress.ip_address(pools[0]["ipRangeStart"]))
    pool_end   = int(ipaddress.ip_address(pools[0]["ipRangeEnd"]))
    print(f"IP pool: {ipaddress.ip_address(pool_start)} – {ipaddress.ip_address(pool_end)}")
else:
    pool_start = pool_end = None
    print("WARNING: No IP assignment pool configured on network")

# ── 4b. Process all members ──
_, members = curl_json("GET", "member")
if not isinstance(members, list):
    members = []

now_ms   = int(time.time() * 1000)
used_ips = set()
self_ips = []

for m in members:
    nid    = m.get("nodeId", "")
    auth   = m.get("authorized", False)
    seen   = m.get("lastSeen", 0)
    ips    = m.get("config", {}).get("ipAssignments", [])

    used_ips.update(ips)
    if nid == NODE_ID:
        self_ips = ips

    # Protected nodes: re-authorize if they got de-authorized
    if nid in SKIP_NODES and not auth:
        code, _ = curl_json("POST", f"member/{nid}",
                            {"config": {"authorized": True}})
        print(f"  Re-authorized protected node {nid[:10]} (HTTP {code})")

    # Purge stale unauthorized members (skip protected nodes)
    if not auth and nid not in SKIP_NODES:
        age = now_ms - seen
        if age > STALE_MS:
            code, _ = curl_json("DELETE", f"member/{nid}")
            print(f"  Purged stale member {nid[:10]} "
                  f"(unseen {age // 60_000} min, HTTP {code})")
        else:
            print(f"  Skipping unauthorized {nid[:10]} "
                  f"(seen {age // 60_000} min ago, not stale)")

# ── 4c. Authorize self ──
code, _ = curl_json("POST", f"member/{NODE_ID}",
                    {"config": {"authorized": True}})
print(f"Self authorization: HTTP {code}")

# ── 4d. Assign IP if pool exists and self has none ──
if not self_ips and pool_start:
    for candidate in range(pool_start, pool_end + 1):
        ip = str(ipaddress.ip_address(candidate))
        if ip not in used_ips:
            code, _ = curl_json("POST", f"member/{NODE_ID}",
                                {"config": {"ipAssignments": [ip]}})
            print(f"IP assigned: {ip} (HTTP {code})")
            break
    else:
        print("WARNING: No available IPs in pool range")
elif self_ips:
    print(f"IP already assigned: {self_ips[0]}")
else:
    print("No IP pool — relying on ZeroTier auto-assignment")

print("ZeroTier auto-join complete.")
PYEOF

echo "ZeroTier auto-join script finished."
SCRIPT

chmod 700 /usr/local/sbin/zerotier-auto-join.sh

# Create a systemd service to run the auto-join script on boot
cat > /etc/systemd/system/zerotier-auto-join.service << 'UNIT'
[Unit]
Description=ZeroTier Auto-Join, Authorize, and IP Assignment
After=network-online.target zerotier-one.service
Wants=network-online.target zerotier-one.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zerotier-auto-join.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable zerotier-one
systemctl enable zerotier-auto-join.service

echo "==> [03] ZeroTier install and boot script setup complete"

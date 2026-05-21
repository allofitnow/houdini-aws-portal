#!/usr/bin/env bash
# 03_zerotier.sh
# Install ZeroTier client and join the render farm overlay network.
#
# MVP: Node authorization is manual via https://my.zerotier.com/network/d3ecf5726d14ac76
# Future: automate approval via ZeroTier Central API using a token in Secrets Manager.

LOG=/var/log/ami-build.log
exec >> "$LOG" 2>&1

ZT_NETWORK="d3ecf5726d14ac76"

echo "==> [03] ZeroTier install started at $(date)"

# Install ZeroTier via official script
curl -s https://install.zerotier.com | bash

systemctl enable zerotier-one
systemctl start zerotier-one

# Wait for daemon to be ready
sleep 5

# Join the render farm network
zerotier-cli join "$ZT_NETWORK"

NODE_ID=$(zerotier-cli info | awk '{print $3}')

echo "==> [03] ZeroTier node ID: ${NODE_ID}"
echo "==> [03] ACTION REQUIRED: Authorize this node at:"
echo "         https://my.zerotier.com/network/${ZT_NETWORK}"
echo "==> [03] ZeroTier install complete"

#!/usr/bin/env bash
# Open the CDN fallback port (2053/tcp) to Cloudflare's IP ranges ONLY.
# Run this AFTER scripts/firewall.sh, and only if you've enabled the Cloudflare CDN fallback
# (see docs/cloudflare-fallback.md). Until you run this, the 2053 inbound is firewalled off.
#
#   sudo scripts/firewall-cdn.sh
#
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }
command -v ufw  >/dev/null 2>&1 || { echo "ufw not installed — run scripts/firewall.sh first."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl required."; exit 1; }

echo "Fetching Cloudflare IPv4 ranges..."
RANGES="$(curl -fsS https://www.cloudflare.com/ips-v4)" || { echo "Failed to fetch Cloudflare IPs."; exit 1; }
[[ -n "$RANGES" ]] || { echo "Empty Cloudflare IP list."; exit 1; }

# Remove any prior CDN rules so re-runs stay idempotent.
while ufw status numbered | grep -q 'cloudflare cdn fallback'; do
  n="$(ufw status numbered | grep 'cloudflare cdn fallback' | head -n1 | sed 's/\].*//; s/.*\[//')"
  yes | ufw delete "$n" >/dev/null
done

while IFS= read -r cidr; do
  [[ -n "$cidr" ]] && ufw allow from "$cidr" to any port 2053 proto tcp comment 'cloudflare cdn fallback'
done <<< "$RANGES"

ufw reload
echo "Done — 2053/tcp now reachable only from Cloudflare edge IPs."
echo "Cloudflare's ranges change occasionally; re-run this script after they update."
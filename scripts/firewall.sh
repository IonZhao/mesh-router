#!/usr/bin/env bash
# VPS firewall (ufw). Public exposure = ONLY the proxy inbounds + ACME.
# Admin surfaces (clash-api 9090, netdata 19999, uptime-kuma 3001, vnstat 8685) are reachable
# ONLY over Tailscale (100.64.0.0/10), never the public internet.
#
#   sudo scripts/firewall.sh
#
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

command -v ufw >/dev/null 2>&1 || { echo "Installing ufw..."; apt-get update -y && apt-get install -y ufw; }

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH — keep open for initial setup. Tighten to Tailscale-only later (see README hardening).
ufw allow 22/tcp comment 'ssh'

# Public proxy inbounds.
ufw allow 443/tcp  comment 'vless-reality'
ufw allow 8443/udp comment 'hysteria2'
ufw allow 80/tcp   comment 'acme http-01 challenge'

# Everything from the Tailscale network is trusted (covers all admin ports + the VPS<->Mac hop).
ufw allow from 100.64.0.0/10 comment 'tailscale net'

ufw --force enable
ufw status verbose

echo
echo "Admin ports (9090/19999/3001/8685) are now reachable ONLY via Tailscale."
echo "To later lock SSH to Tailscale only: 'ufw delete allow 22/tcp' once you confirm Tailscale SSH works."

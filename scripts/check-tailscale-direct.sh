#!/usr/bin/env bash
# Alert when the VPS<->Mac Tailscale link falls back to a DERP relay (throughput collapses).
# Run from cron (e.g. every 5 min). On DERP, optionally hit an Uptime Kuma "push" monitor URL
# so you get notified through the same channel as everything else.
#
#   KUMA_PUSH_URL=http://<vps-ts-ip>:3001/api/push/<token> ./check-tailscale-direct.sh
#   PEER=mac-mini-exit ./check-tailscale-direct.sh        # match on peer hostname
#
# Exit 0 = direct (good); exit 1 = relayed/down (bad).
set -euo pipefail

PEER="${PEER:-mac-mini-exit}"
KUMA_PUSH_URL="${KUMA_PUSH_URL:-}"

# Works whether tailscale runs on the host or in the 'tailscale' docker container.
if command -v tailscale >/dev/null 2>&1; then
  STATUS_JSON="$(tailscale status --json)"
elif docker ps --format '{{.Names}}' | grep -qx tailscale; then
  STATUS_JSON="$(docker exec tailscale tailscale status --json)"
else
  echo "tailscale CLI not found (host or container)."; exit 2
fi

# Pull the peer's connection state. "Relay" non-empty => going through DERP.
LINE="$(printf '%s' "$STATUS_JSON" | tr ',' '\n' | grep -A20 "$PEER" || true)"
RELAY="$(printf '%s' "$STATUS_JSON" | grep -o "\"Relay\":\"[^\"]*\"" | head -n1 | sed 's/.*:"//;s/"//')"
CURADDR="$(printf '%s' "$STATUS_JSON" | grep -o "\"CurAddr\":\"[^\"]*\"" | head -n1 | sed 's/.*:"//;s/"//')"

notify() { [[ -n "$KUMA_PUSH_URL" ]] && curl -fsS "${KUMA_PUSH_URL}?status=${1}&msg=$(printf '%s' "$2" | sed 's/ /%20/g')" >/dev/null 2>&1 || true; }

if [[ -n "$CURADDR" ]]; then
  echo "OK: direct connection to peer ($CURADDR)"
  notify up "direct:$CURADDR"
  exit 0
else
  echo "WARN: peer reachable only via DERP relay (${RELAY:-unknown}) — throughput degraded"
  notify down "DERP relay ${RELAY:-?}"
  exit 1
fi

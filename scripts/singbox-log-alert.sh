#!/usr/bin/env bash
# VPS health probe for cron: count the sing-box log lines that mean "traffic is failing" in the last
# window and report them, optionally to an Uptime Kuma push monitor (same channel as the other
# alerts). Pairs with scripts/check-tailscale-direct.sh.
#
#   */10 * * * * /root/mesh-router/scripts/singbox-log-alert.sh >/dev/null 2>&1
#
# Counted (log LINES, last $WINDOW, default 10m):
#   unreachable  "network is unreachable"       — the host dialed an address family it has no route
#                                                 for (IPv6 on an IPv4-only VPS); user traffic fails
#   dial_dest    "failed to dial dest"          — the Reality handshake target could not be reached;
#                                                 every Reality client sees connect error: EOF
#   invalid      "processed invalid connection" — Reality rejected a handshake. Internet scanners
#                                                 cause a steady trickle; a jump means your own
#                                                 clients are being rejected
#   errors       all ERROR lines
# Status is `down` when unreachable > $ALERT_UNREACHABLE_MAX (0), dial_dest > $ALERT_DIAL_DEST_MAX
# (0) or invalid > $ALERT_INVALID_MAX (unset = never). Exit 0 = up, 1 = down.
#
# Push: set KUMA_PUSH_URL (or KUMA_PUSH_URL_SINGBOX in secrets/vps.env, which is sourced when
# present) to the monitor's push URL; the script appends ?status=&msg=. ALERT_DRY_RUN=1 prints the
# query instead of sending it. SINGBOX_LOG_INPUT=<file> reads a saved log instead of `docker logs`
# (tests). The push token is never printed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOW="${WINDOW:-10m}"
CONTAINER="${SINGBOX_CONTAINER:-sing-box}"

if [[ -z "${KUMA_PUSH_URL:-}" && -f "$SCRIPT_DIR/../secrets/vps.env" ]]; then
  KUMA_PUSH_URL="$(grep -E '^KUMA_PUSH_URL_SINGBOX=' "$SCRIPT_DIR/../secrets/vps.env" | head -1 | cut -d= -f2 | awk '{print $1}')"
fi
KUMA_PUSH_URL="${KUMA_PUSH_URL:-}"

if [[ -n "${SINGBOX_LOG_INPUT:-}" ]]; then
  LOG="$(cat "$SINGBOX_LOG_INPUT")"
else
  command -v docker >/dev/null 2>&1 || { echo "status=unknown error=docker-not-found"; exit 2; }
  LOG="$(docker logs "$CONTAINER" --since "$WINDOW" 2>&1)" || { echo "status=unknown error=docker-logs-failed"; exit 2; }
fi

count() { printf '%s\n' "$LOG" | grep -c -F -- "$1"; }
unreachable="$(count 'network is unreachable')"
dial_dest="$(count 'failed to dial dest')"
invalid="$(count 'processed invalid connection')"
errors="$(count ' ERROR ')"

status=up
[[ "$unreachable" -gt "${ALERT_UNREACHABLE_MAX:-0}" ]] && status=down
[[ "$dial_dest" -gt "${ALERT_DIAL_DEST_MAX:-0}" ]] && status=down
[[ -n "${ALERT_INVALID_MAX:-}" && "$invalid" -gt "$ALERT_INVALID_MAX" ]] && status=down

summary="unreachable=$unreachable dial_dest=$dial_dest invalid=$invalid errors=$errors window=$WINDOW"
echo "status=$status $summary"

if [[ -n "$KUMA_PUSH_URL" ]]; then
  # msg is URL-encoded by hand (only = and space occur); the token stays inside KUMA_PUSH_URL.
  query="?status=$status&msg=$(printf '%s' "$summary" | sed 's/=/%3D/g; s/ /%20/g')"
  if [[ -n "${ALERT_DRY_RUN:-}" ]]; then
    echo "push: $query"
  else
    curl -fsS --max-time 15 "${KUMA_PUSH_URL}${query}" >/dev/null 2>&1 || echo "push: failed (Uptime Kuma unreachable)"
  fi
fi

[[ "$status" == up ]]

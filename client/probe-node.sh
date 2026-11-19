#!/usr/bin/env bash
# Probe ONE proxy (or group) of the rendered client config through an isolated mihomo instance,
# without touching the running Clash Verge / mihomo. Useful to tell "this node is broken" apart
# from "the group picked a broken node".
#
#   client/probe-node.sh <node-or-group> [count]      e.g.  client/probe-node.sh reality-vps 5
#
# Reads client/clash-meta.yaml (run render-client-config.sh first), keeps only its proxies and
# proxy-groups, pins a `select` group to <node-or-group>, listens on 127.0.0.1:$PROBE_PORT
# (default 17890), requests https://www.gstatic.com/generate_204 <count> times (default 3), prints
# http=<code> per try and the distinct mihomo warnings/errors with server addresses replaced by
# <server>, then stops.
#
# Run it with the client's TUN mode OFF: with TUN on, the probe's own dials are captured by the
# running client and carried through ITS node, so the result says nothing about the probed path.
# The probe refuses to run when Clash Verge's runtime config shows TUN enabled
# (PROBE_IGNORE_TUN=1 overrides, e.g. when another client is in use).
#
# Env: PROBE_PORT, PROBE_CONFIG, PROBE_DIAL_TIMEOUT (seconds per try, default 10),
#      PROBE_VERGE_RUNTIME (Verge runtime config to inspect), PROBE_DRY_RUN=1 (print the plan only).
# Exit 0 = every try returned 204; 1 = some try failed; 2 = could not run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib.sh
source "$SCRIPT_DIR/../scripts/lib.sh"

NODE="${1:?usage: $0 <node-or-group> [count]}"
COUNT="${2:-3}"
PORT="${PROBE_PORT:-17890}"
CONFIG="${PROBE_CONFIG:-$SCRIPT_DIR/clash-meta.yaml}"
DIAL_TIMEOUT="${PROBE_DIAL_TIMEOUT:-10}"
WORK="$SCRIPT_DIR/.probe"
URL="https://www.gstatic.com/generate_204"
BUDGET=$((30 + 12 * COUNT))          # seconds mihomo may live: start-up + count × (dial + margin)

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

[[ "$COUNT" =~ ^[1-9][0-9]*$ ]] || die "count must be a positive integer."
[[ -f "$CONFIG" ]] || die "$CONFIG not found; run client/render-client-config.sh first."
BIN="$(find_mihomo)"
[[ -n "$BIN" ]] || die "no mihomo binary found (set MIHOMO_BIN)."
grep -qE "^\s*- (name: )?['\"]?$NODE['\"]?\s*$|name: ['\"]?$NODE['\"]?\s*$" "$CONFIG" \
  || die "no proxy or group named '$NODE' in $CONFIG."

# Refuse while the running client's TUN would capture our dials.
VERGE_RUNTIME="${PROBE_VERGE_RUNTIME:-${APPDATA:+$(to_posix "$APPDATA")/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml}}"
if [[ -z "${PROBE_IGNORE_TUN:-}" && -n "$VERGE_RUNTIME" && -f "$VERGE_RUNTIME" ]] \
   && awk '/^[A-Za-z]/{s=$1} s=="tun:" && /^[[:space:]]+enable:[[:space:]]*true/{f=1} END{exit !f}' "$VERGE_RUNTIME"; then
  die "the client's TUN mode is on ($VERGE_RUNTIME); the probe would be tunnelled through the client's own node. Turn TUN off first (PROBE_IGNORE_TUN=1 to override)."
fi

# Server addresses of every proxy, to scrub from printed errors (probe output gets pasted around).
mapfile -t SERVERS < <(awk '/^[A-Za-z]/{s=$1} s=="proxies:" && /^[[:space:]]+server:/{print $2}' "$CONFIG" | tr -d "'\"" | sort -u)
scrub() {
  local s expr=""
  for s in "${SERVERS[@]}"; do [[ -n "$s" ]] && expr+="s/$(printf '%s' "$s" | sed 's/[.[\*^$]/\\&/g')/<server>/g;"; done
  sed -E "s/127\.0\.0\.1:[0-9]+/127.0.0.1:*/g; s/192\.168\.[0-9.]+:[0-9]+/<lan>:*/g; ${expr}"
}

echo "probe: $NODE × $COUNT via 127.0.0.1:$PORT, up to $BUDGET s"
[[ -n "${PROBE_DRY_RUN:-}" ]] && exit 0

rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# Keep only top-level keys that describe nodes; drop listeners, DNS, TUN, rules and providers.
{
  printf 'mixed-port: %s\nallow-lan: false\nlog-level: warning\nmode: rule\n' "$PORT"
  awk -v node="$NODE" '
    /^[A-Za-z][A-Za-z0-9-]*:/ {
      key = $1; sub(":", "", key)
      keep = (key == "proxies" || key == "proxy-groups")
      if (keep) print
      if (key == "proxy-groups") printf "  - { name: PROBE, type: select, proxies: [\"%s\"] }\n", node
      next
    }
    keep { print }
  ' "$CONFIG"
  grep -q '^proxy-groups:' "$CONFIG" \
    || printf 'proxy-groups:\n  - { name: PROBE, type: select, proxies: ["%s"] }\n' "$NODE"
  printf 'rules:\n  - MATCH,PROBE\n'
} >"$WORK/config.yaml"

timeout "$BUDGET" "$BIN" -d "$(native "$WORK")" -f "$(native "$WORK/config.yaml")" >"$WORK/mihomo.log" 2>&1 &
pid=$!
ready=0
for _ in $(seq 1 40); do
  if curl -s -o /dev/null --noproxy '*' --max-time 1 "http://127.0.0.1:$PORT"; then ready=1; break; fi
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.5
done
if [[ $ready -ne 1 ]]; then
  echo "mihomo did not start; last log lines:"
  tail -5 "$WORK/mihomo.log" | scrub
  kill "$pid" 2>/dev/null
  exit 2
fi

good=0
for i in $(seq 1 "$COUNT"); do
  code="$(curl -s -o /dev/null --max-time "$DIAL_TIMEOUT" -x "http://127.0.0.1:$PORT" -w '%{http_code}' "$URL")"
  printf '  try%s %s http=%s\n' "$i" "$NODE" "$code"
  [[ "$code" == "204" ]] && good=$((good + 1))
done
sleep 1   # let a pending dial failure reach the log

kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
grep -E 'level=(warning|error)' "$WORK/mihomo.log" \
  | sed -E 's/.*msg="//; s/"$//' | scrub | cut -c1-200 | sort | uniq -c | head -6

echo "$good/$COUNT tries returned 204"
[[ "$good" -eq "$COUNT" ]]

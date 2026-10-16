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
# http=<code> per try and the distinct mihomo warnings/errors, then stops.
#
# Exit 0 = every try returned 204.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib.sh
source "$SCRIPT_DIR/../scripts/lib.sh"

NODE="${1:?usage: $0 <node-or-group> [count]}"
COUNT="${2:-3}"
PORT="${PROBE_PORT:-17890}"
CONFIG="${PROBE_CONFIG:-$SCRIPT_DIR/clash-meta.yaml}"
WORK="$SCRIPT_DIR/.probe"
URL="https://www.gstatic.com/generate_204"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

[[ -f "$CONFIG" ]] || die "$CONFIG not found; run client/render-client-config.sh first."
BIN="$(find_mihomo)"
[[ -n "$BIN" ]] || die "no mihomo binary found (set MIHOMO_BIN)."
grep -qE "^\s*- (name: )?['\"]?$NODE['\"]?\s*$|name: ['\"]?$NODE['\"]?\s*$" "$CONFIG" \
  || die "no proxy or group named '$NODE' in $CONFIG."

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

timeout 120 "$BIN" -d "$(native "$WORK")" -f "$(native "$WORK/config.yaml")" >"$WORK/mihomo.log" 2>&1 &
pid=$!
ready=0
for _ in $(seq 1 40); do
  if curl -s -o /dev/null --noproxy '*' --max-time 1 "http://127.0.0.1:$PORT"; then ready=1; break; fi
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.5
done
if [[ $ready -ne 1 ]]; then
  echo "mihomo did not start; last log lines:"
  tail -5 "$WORK/mihomo.log"
  kill "$pid" 2>/dev/null
  exit 2
fi

good=0
for i in $(seq 1 "$COUNT"); do
  code="$(curl -s -o /dev/null --max-time 10 -x "http://127.0.0.1:$PORT" -w '%{http_code}' "$URL")"
  printf '  try%s %s http=%s\n' "$i" "$NODE" "$code"
  [[ "$code" == "204" ]] && good=$((good + 1))
done

kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
grep -E 'level=(warning|error)' "$WORK/mihomo.log" \
  | sed -E 's/.*msg="//; s/"$//; s/127\.0\.0\.1:[0-9]+/127.0.0.1:*/g' \
  | cut -c1-200 | sort | uniq -c | head -6

echo "$good/$COUNT tries returned 204"
[[ "$good" -eq "$COUNT" ]]

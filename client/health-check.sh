#!/usr/bin/env bash
# Client-side health check, meant to run every 5 minutes from the task scheduler
# (client/install-health-task.sh registers it). It asks the running mihomo (Clash Verge) which node
# the PROXY group is using, whether each node passes the group's own test URL, and how old the rule
# sets are; appends one CSV row per run; and raises an alert ONCE when something has been wrong for
# a while, plus one "recovered" when it is fixed:
#   - a node has been dead for >= HEALTH_DEAD_MIN minutes (10)
#   - PROXY has not been on HEALTH_PREFERRED (hy2-vps) for >= HEALTH_OFF_PREFERRED_MIN minutes (10)
#   - a remote rule set is older than HEALTH_RULES_STALE_DAYS days (3)
#   - the controller has been unreachable for >= HEALTH_UNREACHABLE_MIN minutes (10): Clash Verge
#     not running, its external controller off, or the secret rejected
#
# Controller: MIHOMO_API (host:port) + MIHOMO_SECRET, else read from Clash Verge's runtime config
# (%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml). In Verge, Settings ->
# Clash -> External controller must be ON (127.0.0.1:9097 by default) for this to work. The secret
# is sent on curl's stdin, never on a command line.
#
# Files (HEALTH_DIR, default %LOCALAPPDATA%\mesh-router or ~/.local/state/mesh-router):
#   health.csv  time,status,group_now,nodes,oldest_rules_h      state.env  alert bookkeeping
#   health.env  optional KEY=value settings for the scheduled task (HEALTH_*, MIHOMO_API,
#               MIHOMO_SECRET); values already in the environment win; the file is parsed, not run
# Alerts: HEALTH_NOTIFY=toast (Windows notification, default) | echo (print only) | none, and an
# optional Uptime Kuma push monitor (HEALTH_KUMA_PUSH_URL, pasted as Kuma shows it; the URL is used
# up to the token). Every alert is also printed as "NOTIFY: ...". HEALTH_KUMA_DRY_RUN=1 prints the
# push (token redacted) instead of sending it.
# Exit 0 = ok, 1 = an alert condition is active, 2 = could not check.
# Tests: HEALTH_API_FIXTURE_DIR=<dir of saved API JSON>, HEALTH_NOW=<epoch>.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib.sh
source "$SCRIPT_DIR/../scripts/lib.sh"

if [[ -n "${HEALTH_DIR:-}" ]]; then DIR="$HEALTH_DIR"
elif [[ -n "${LOCALAPPDATA:-}" ]]; then DIR="$(to_posix "$LOCALAPPDATA")/mesh-router"
else DIR="${XDG_STATE_HOME:-$HOME/.local/state}/mesh-router"; fi
mkdir -p "$DIR" 2>/dev/null && [[ -w "$DIR" ]] || { echo "status=error cannot write $DIR"; exit 2; }
if [[ -f "$DIR/health.env" ]]; then
  while IFS='=' read -r k v || [[ -n "$k" ]]; do
    [[ "$k" =~ ^(HEALTH_[A-Z_]+|MIHOMO_API|MIHOMO_SECRET)$ ]] || continue
    v="${v%%[[:space:]]#*}"; v="${v%$'\r'}"; v="${v%"${v##*[![:space:]]}"}"; v="${v%\"}"; v="${v#\"}"
    [[ -n "${!k:-}" ]] || export "$k=$v"
  done <"$DIR/health.env"
fi

num() { if [[ "$1" =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }   # num <value> <default>
NOW="$(num "${HEALTH_NOW:-}" "$(date +%s)")"
GROUP="${HEALTH_GROUP:-PROXY}"
PREFERRED="${HEALTH_PREFERRED:-hy2-vps}"
DEAD_MIN="$(num "${HEALTH_DEAD_MIN:-}" 10)"
OFF_MIN="$(num "${HEALTH_OFF_PREFERRED_MIN:-}" 10)"
UNREACH_MIN="$(num "${HEALTH_UNREACHABLE_MIN:-}" 10)"
STALE_DAYS="$(num "${HEALTH_RULES_STALE_DAYS:-}" 3)"
NOTIFY_MODE="${HEALTH_NOTIFY:-toast}"
STATE="$DIR/state.env"
CSV="$DIR/health.csv"
WORK="$(mktemp -d)" || { echo "status=error cannot create a temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT
[[ -f "$STATE" ]] || : >"$STATE"

# ---- small key=value state store (bash 3.2 friendly) ---------------------------------------------
skey() { printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'; }
state_get() { grep -E "^$(skey "$1")=" "$STATE" | head -1 | cut -d= -f2- | tr -d '\r'; }
state_epoch() { num "$(state_get "$1")" ""; }     # a damaged value reads as "never seen"
state_set() { local k; k="$(skey "$1")"; grep -vE "^$k=" "$STATE" >"$STATE.new"; printf '%s=%s\n' "$k" "$2" >>"$STATE.new"; mv "$STATE.new" "$STATE"; }
state_del() { local k; k="$(skey "$1")"; grep -vE "^$k=" "$STATE" >"$STATE.new"; mv "$STATE.new" "$STATE"; }

# ---- notifications -------------------------------------------------------------------------------
toast() {
  MESH_TOAST_MSG="$1" powershell -NoProfile -NonInteractive -Command '
    try {
      [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
      $t = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
      $n = $t.GetElementsByTagName("text")
      $n.Item(0).AppendChild($t.CreateTextNode("mesh-router")) | Out-Null
      $n.Item(1).AppendChild($t.CreateTextNode($env:MESH_TOAST_MSG)) | Out-Null
      $id = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"
      [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($id).Show([Windows.UI.Notifications.ToastNotification]::new($t))
    } catch { exit 1 }' >/dev/null 2>&1
}
notify() {
  echo "NOTIFY: $1"
  case "$NOTIFY_MODE" in
    toast) if command -v powershell >/dev/null 2>&1; then toast "$1"; elif command -v notify-send >/dev/null 2>&1; then notify-send "mesh-router" "$1"; fi ;;
    *) ;;
  esac
}
# alert_once <key> <message>: notify the first time a condition is seen; remember that we did.
alert_once() { [[ -n "$(state_get "alerted_$1")" ]] && return; notify "$2"; state_set "alerted_$1" "$NOW"; }
# clear_alert <key> <recovered message>: notify once when a previously alerted condition is gone.
clear_alert() { [[ -n "$(state_get "alerted_$1")" ]] && notify "$2"; state_del "alerted_$1"; }

# ---- controller access ---------------------------------------------------------------------------
API=""; SECRET=""
resolve_controller() {
  API="${MIHOMO_API:-}"; SECRET="${MIHOMO_SECRET:-}"
  [[ -n "$API" ]] && return 0
  local rt="${HEALTH_VERGE_RUNTIME:-${APPDATA:+$(to_posix "$APPDATA")/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml}}"
  [[ -n "$rt" && -f "$rt" ]] || return 1
  API="$(grep -E '^external-controller:' "$rt" | head -1 | cut -d: -f2- | tr -d " '\"\r")"
  SECRET="$(grep -E '^secret:' "$rt" | head -1 | cut -d: -f2- | tr -d " '\"\r")"
  [[ -n "$API" ]]
}
# api_get <path> <outfile> <jq test the answer must pass>
# -f: a 401 (wrong secret) or 404 is a failure, not JSON to parse. The bearer token goes to curl on
# stdin (-H @-), so it never shows in the process list. Path segments are URL-encoded (node names
# may contain spaces or non-ASCII).
api_get() {
  if [[ -n "${HEALTH_API_FIXTURE_DIR:-}" ]]; then
    local f="$HEALTH_API_FIXTURE_DIR/$(printf '%s' "${1#/}" | tr '/' '-').json"
    [[ -f "$f" ]] && cp "$f" "$2"
  else
    local p; p="$(printf '%s' "$1" | jq -Rr 'split("/") | map(@uri) | join("/")')"
    printf 'Authorization: Bearer %s\n' "$SECRET" |
      curl -fsS --noproxy '*' --max-time 5 -H @- "http://$API$p" -o "$2" 2>/dev/null
  fi && jq -e "$3" "$2" >/dev/null 2>&1
}

csv_row() { # csv_row <status> <group_now> <nodes> <oldest_rules_h>
  [[ -f "$CSV" ]] || echo "time,status,group_now,nodes,oldest_rules_h" >"$CSV"
  printf '%s,%s,%s,%s,%s\n' "$(date -u -d "@$NOW" +%FT%TZ)" "$1" "$2" "$3" "$4" >>"$CSV"
}
push_kuma() { # push_kuma <up|down> <msg>
  local base="${HEALTH_KUMA_PUSH_URL:-}" query
  base="${base%%\?*}"                       # Kuma shows "...?status=up&msg=OK&ping="; we send our own
  [[ -n "$base" ]] || return 0
  query="?status=$1&msg=$(printf '%s' "$2" | sed 's/%/%25/g; s/&/%26/g; s/=/%3D/g; s/ /%20/g; s/,/%2C/g; s/;/%3B/g')"
  if [[ -n "${HEALTH_KUMA_DRY_RUN:-}" ]]; then echo "push: ${base%/*}/***$query"; return 0; fi
  curl -fsS --max-time 10 "$base$query" >/dev/null 2>&1 || true
}
# controller_down <reason>: record the run, alert once after UNREACH_MIN minutes, exit 2.
controller_down() {
  local first minutes
  first="$(state_epoch first_unreachable)"
  [[ -n "$first" ]] || { first="$NOW"; state_set first_unreachable "$NOW"; }
  minutes=$(( (NOW - first) / 60 ))
  if [[ "$minutes" -ge "$UNREACH_MIN" ]]; then
    alert_once controller "mihomo controller unreachable for $minutes min: $1"
  fi
  csv_row unreachable - - -
  push_kuma down "controller unreachable"
  echo "status=unreachable ($1)"
  exit 2
}

# ---- 1. the group --------------------------------------------------------------------------------
if [[ -z "${HEALTH_API_FIXTURE_DIR:-}" ]] && ! resolve_controller; then
  controller_down "turn on Clash Verge's external controller (Settings -> Clash) or set MIHOMO_API"
fi
if ! api_get "/proxies/$GROUP" "$WORK/group.json" '.all | type == "array"'; then
  controller_down "no mihomo answer from ${API:-the fixture} for group $GROUP (Clash Verge not running? wrong secret?)"
fi
clear_alert controller "mihomo controller reachable again"
state_del first_unreachable

group_now="$(jq -r '.now // ""' "$WORK/group.json" | tr -d '\r')"
test_url="$(jq -r '.testUrl // ""' "$WORK/group.json" | tr -d '\r')"
alerting=0
nodes_field=""

# ---- 2. each node --------------------------------------------------------------------------------
# mihomo keeps one health result per test URL (.extra[url]); the group acts on the result for ITS
# URL, so that is what counts here. .alive alone can stay true on another URL's result.
while IFS= read -r node; do
  [[ -n "$node" ]] || continue
  alive=false; delay=""
  if api_get "/proxies/$node" "$WORK/node.json" 'has("alive")'; then
    result='(if $u != "" and ((.extra // {})[$u] | type) == "object" then .extra[$u] else . end)'
    alive="$(jq -r --arg u "$test_url" "$result | .alive // false" "$WORK/node.json" | tr -d '\r')"
    delay="$(jq -r --arg u "$test_url" "$result | .history // [] | last // {} | .delay // \"\"" "$WORK/node.json" | tr -d '\r')"
  fi
  if [[ "$alive" == "true" ]]; then
    nodes_field+="$node:alive:$delay;"
    clear_alert "dead_$node" "$node recovered"
    state_del "first_dead_$node"
  else
    nodes_field+="$node:dead:$delay;"
    first="$(state_epoch "first_dead_$node")"
    [[ -n "$first" ]] || { first="$NOW"; state_set "first_dead_$node" "$NOW"; }
    minutes=$(( (NOW - first) / 60 ))
    if [[ "$minutes" -ge "$DEAD_MIN" ]]; then
      alerting=1
      alert_once "dead_$node" "$node has been dead for $minutes min"
    fi
  fi
done < <(jq -r '.all[]? // empty' "$WORK/group.json" | tr -d '\r')

# ---- 3. is the group where it should be? ---------------------------------------------------------
if [[ "$group_now" == "$PREFERRED" ]]; then
  clear_alert off_preferred "$GROUP back on $PREFERRED"
  state_del off_preferred_since
else
  since="$(state_epoch off_preferred_since)"
  [[ -n "$since" ]] || { since="$NOW"; state_set off_preferred_since "$NOW"; }
  minutes=$(( (NOW - since) / 60 ))
  if [[ "$minutes" -ge "$OFF_MIN" ]]; then
    alerting=1
    alert_once off_preferred "$GROUP is on ${group_now:-nothing}, not $PREFERRED, for $minutes min"
  fi
fi

# ---- 4. rule-set freshness ------------------------------------------------------------------------
oldest_h="-"
if api_get "/providers/rules" "$WORK/providers.json" '.providers | type == "object"'; then
  oldest=0
  while IFS=$'\t' read -r name updated; do
    [[ -n "$updated" && "$updated" != null ]] || continue
    upd="$(date -d "$updated" +%s 2>/dev/null || echo "$NOW")"
    if [[ "$upd" -lt 946684800 ]]; then   # mihomo reports 0001-01-01 for a set it never managed to load
      alerting=1
      alert_once "stale_$name" "rule set $name has never been loaded (file missing and download failed?)"
      continue
    fi
    age=$(( NOW - upd ))
    [[ "$age" -gt "$oldest" ]] && oldest="$age"
    days=$(( age / 86400 ))
    if [[ "$days" -ge "$STALE_DAYS" ]]; then
      alerting=1
      alert_once "stale_$name" "rule set $name last updated $days days ago"
    else
      clear_alert "stale_$name" "rule set $name is fresh again"
    fi
  done < <(jq -r '.providers | to_entries[] | select(.value.vehicleType == "HTTP") | [.key, .value.updatedAt] | @tsv' "$WORK/providers.json" | tr -d '\r')
  oldest_h=$(( oldest / 3600 ))
fi

# ---- 5. record and report ------------------------------------------------------------------------
if [[ "$alerting" -eq 1 ]]; then status=alert; else status=ok; fi
csv_row "$status" "${group_now:--}" "${nodes_field%;}" "$oldest_h"
push_kuma "$([[ $status == ok ]] && echo up || echo down)" "$status group=$group_now $nodes_field"
echo "status=$status group=${group_now:--} nodes=${nodes_field%;} oldest_rules_h=$oldest_h"
[[ "$status" == ok ]]

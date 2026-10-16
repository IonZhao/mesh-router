#!/usr/bin/env bash
# Client-side health check, meant to run every 5 minutes from the task scheduler
# (client/install-health-task.sh registers it). It asks the running mihomo (Clash Verge) which node
# the PROXY group is using, whether each node is alive, and how old the rule sets are; appends one
# CSV row per run; and raises an alert ONCE when something has been wrong for a while, plus one
# "recovered" when it is fixed:
#   - a node has been dead for >= HEALTH_DEAD_MIN minutes (10)
#   - PROXY has not been on HEALTH_PREFERRED (hy2-vps) for >= HEALTH_OFF_PREFERRED_MIN minutes (10)
#   - a remote rule set is older than HEALTH_RULES_STALE_DAYS days (3)
#   - the controller cannot be reached (Clash Verge not running, or its external controller is off)
#
# Controller: MIHOMO_API (host:port) + MIHOMO_SECRET, else read from Clash Verge's runtime config
# (%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml). In Verge, Settings ->
# Clash -> External controller must be ON (127.0.0.1:9097 by default) for this to work.
#
# Files (HEALTH_DIR, default %LOCALAPPDATA%\mesh-router or ~/.local/state/mesh-router):
#   health.csv  time,status,group_now,nodes,oldest_rules_h      state.env  alert bookkeeping
# Alerts: HEALTH_NOTIFY=toast (Windows notification, default) | echo (print only) | none, and an
# optional Uptime Kuma push monitor (HEALTH_KUMA_PUSH_URL). Every alert is also printed as
# "NOTIFY: ...". Exit 0 = ok, 1 = an alert condition is active, 2 = could not check.
# Tests: HEALTH_API_FIXTURE_DIR=<dir of saved API JSON>, HEALTH_NOW=<epoch>.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib.sh
source "$SCRIPT_DIR/../scripts/lib.sh"

NOW="${HEALTH_NOW:-$(date +%s)}"
GROUP="${HEALTH_GROUP:-PROXY}"
PREFERRED="${HEALTH_PREFERRED:-hy2-vps}"
DEAD_MIN="${HEALTH_DEAD_MIN:-10}"
OFF_MIN="${HEALTH_OFF_PREFERRED_MIN:-10}"
STALE_DAYS="${HEALTH_RULES_STALE_DAYS:-3}"
NOTIFY_MODE="${HEALTH_NOTIFY:-toast}"
if [[ -n "${HEALTH_DIR:-}" ]]; then DIR="$HEALTH_DIR"
elif [[ -n "${LOCALAPPDATA:-}" ]]; then DIR="$(to_posix "$LOCALAPPDATA")/mesh-router"
else DIR="${XDG_STATE_HOME:-$HOME/.local/state}/mesh-router"; fi
mkdir -p "$DIR"
STATE="$DIR/state.env"
CSV="$DIR/health.csv"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
[[ -f "$STATE" ]] || : >"$STATE"

# ---- small key=value state store (bash 3.2 friendly) ---------------------------------------------
skey() { printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'; }
state_get() { grep -E "^$(skey "$1")=" "$STATE" | head -1 | cut -d= -f2-; }
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
# api_get <path> <outfile>
api_get() {
  if [[ -n "${HEALTH_API_FIXTURE_DIR:-}" ]]; then
    local f="$HEALTH_API_FIXTURE_DIR/$(printf '%s' "${1#/}" | tr '/' '-').json"
    [[ -f "$f" ]] && cp "$f" "$2"
  else
    curl -s --noproxy '*' --max-time 5 -H "Authorization: Bearer $SECRET" "http://$API$1" -o "$2" 2>/dev/null
  fi && jq -e . "$2" >/dev/null 2>&1
}

csv_row() { # csv_row <status> <group_now> <nodes> <oldest_rules_h>
  [[ -f "$CSV" ]] || echo "time,status,group_now,nodes,oldest_rules_h" >"$CSV"
  printf '%s,%s,%s,%s,%s\n' "$(date -u -d "@$NOW" +%FT%TZ)" "$1" "$2" "$3" "$4" >>"$CSV"
}
push_kuma() { # push_kuma <up|down> <msg>
  [[ -n "${HEALTH_KUMA_PUSH_URL:-}" ]] || return 0
  curl -fsS --max-time 10 "${HEALTH_KUMA_PUSH_URL}?status=$1&msg=$(printf '%s' "$2" | sed 's/=/%3D/g; s/ /%20/g; s/,/%2C/g')" >/dev/null 2>&1 || true
}

# ---- 1. the group --------------------------------------------------------------------------------
if [[ -z "${HEALTH_API_FIXTURE_DIR:-}" ]] && ! resolve_controller; then
  alert_once controller "mihomo controller unreachable: enable Clash Verge's external controller (Settings -> Clash) so the health check can read it"
  csv_row unreachable - - -
  push_kuma down "controller unreachable"
  echo "status=unreachable"
  exit 2
fi
if ! api_get "/proxies/$GROUP" "$WORK/group.json"; then
  alert_once controller "mihomo controller unreachable (is Clash Verge running with the external controller on?)"
  csv_row unreachable - - -
  push_kuma down "controller unreachable"
  echo "status=unreachable"
  exit 2
fi
clear_alert controller "mihomo controller reachable again"

group_now="$(jq -r '.now // ""' "$WORK/group.json" | tr -d '\r')"
nodes="$(jq -r '.all[]? // empty' "$WORK/group.json" | tr -d '\r')"
alerting=0
nodes_field=""

# ---- 2. each node --------------------------------------------------------------------------------
for node in $nodes; do
  alive=false; delay=""
  if api_get "/proxies/$node" "$WORK/node.json"; then
    alive="$(jq -r '.alive // false' "$WORK/node.json" | tr -d '\r')"
    delay="$(jq -r '.history[-1].delay // ""' "$WORK/node.json" | tr -d '\r')"
  fi
  if [[ "$alive" == "true" ]]; then
    nodes_field+="$node:alive:$delay;"
    clear_alert "dead_$node" "$node recovered"
    state_del "first_dead_$node"
  else
    nodes_field+="$node:dead:$delay;"
    first="$(state_get "first_dead_$node")"
    [[ -n "$first" ]] || { first="$NOW"; state_set "first_dead_$node" "$NOW"; }
    minutes=$(( (NOW - first) / 60 ))
    if [[ "$minutes" -ge "$DEAD_MIN" ]]; then
      alerting=1
      alert_once "dead_$node" "$node has been dead for $minutes min"
    fi
  fi
done

# ---- 3. is the group where it should be? ---------------------------------------------------------
if [[ "$group_now" == "$PREFERRED" ]]; then
  clear_alert off_preferred "$GROUP back on $PREFERRED"
  state_del off_preferred_since
else
  since="$(state_get off_preferred_since)"
  [[ -n "$since" ]] || { since="$NOW"; state_set off_preferred_since "$NOW"; }
  minutes=$(( (NOW - since) / 60 ))
  if [[ "$minutes" -ge "$OFF_MIN" ]]; then
    alerting=1
    alert_once off_preferred "$GROUP is on ${group_now:-nothing}, not $PREFERRED, for $minutes min"
  fi
fi

# ---- 4. rule-set freshness ------------------------------------------------------------------------
oldest_h="-"
if api_get "/providers/rules" "$WORK/providers.json"; then
  oldest=0
  while IFS=$'\t' read -r name updated; do
    [[ -n "$updated" && "$updated" != null ]] || continue
    upd="$(date -d "$updated" +%s 2>/dev/null || echo "$NOW")"
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

#!/usr/bin/env bash
# Offline test suite for the config templates and the validation harness.
# No network, no real secrets. Needs a mihomo binary and a sing-box binary (or Docker);
# see scripts/validate-configs.sh for how they are found.
#
#   bash scripts/test-configs.sh
#
# Exit 0 = every case passed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
V="$SCRIPT_DIR/validate-configs.sh"
VPS_TPL="$REPO_ROOT/vps/sing-box/config.json.template"
CLIENT_TPL="$REPO_ROOT/client/clash-meta.yaml.template"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

ok() { pass=$((pass + 1)); echo "PASS $1"; }
ko() { fail=$((fail + 1)); echo "FAIL $1"; }

# expect <wanted-exit-code> <case-name> <log-pattern|""> <command...>
# Passes only when the exit code matches AND (if given) the output contains the pattern, so a case
# cannot pass because some unrelated step failed first.
expect() {
  local want="$1" name="$2" pattern="$3" rc log
  shift 3
  log="$TMP/$name.log"
  "$@" >"$log" 2>&1
  rc=$?
  if [[ "$rc" -ne "$want" ]]; then
    ko "$name (exit $rc, wanted $want)"
    tail -8 "$log" | sed 's/^/    /'
  elif [[ -n "$pattern" ]] && ! grep -qE "$pattern" "$log"; then
    ko "$name (exit $rc as wanted, but output lacks /$pattern/)"
    tail -8 "$log" | sed 's/^/    /'
  else
    ok "$name"
  fi
}

# --- the real templates pass every available check -------------------------------------------
expect 0 templates_validate "" bash "$V"

# --- the harness catches what it claims to catch -------------------------------------------------
# sing-box rejects an invalid enum value in the VPS config.
sed -E 's/"strategy": "[a-z0-9_]+"/"strategy": "not_a_strategy"/' "$VPS_TPL" >"$TMP/bad-value.json.template"
expect 1 vps_invalid_value_rejected "FAIL vps: sing-box check" \
  env VPS_TEMPLATE="$TMP/bad-value.json.template" bash "$V" --vps

# A template variable that bootstrap.sh would not substitute is caught before deploy.
sed -E 's/"tag": "direct"/"tag": "${NOT_IN_BOOTSTRAP_VARS}"/' "$VPS_TPL" >"$TMP/unknown-var.json.template"
expect 1 vps_unrendered_variable_rejected "not substituted by bootstrap.sh VARS: NOT_IN_BOOTSTRAP_VARS" \
  env VPS_TEMPLATE="$TMP/unknown-var.json.template" bash "$V" --vps

# mihomo rejects a rule that points at a rule-provider that does not exist.
awk '{print} /^rules:/{print "  - RULE-SET,no-such-provider,DIRECT"}' "$CLIENT_TPL" >"$TMP/bad-rule.yaml.template"
expect 1 client_unknown_provider_rejected "FAIL client: mihomo -t" \
  env CLIENT_TEMPLATE="$TMP/bad-rule.yaml.template" bash "$V" --client

# --- VPS template behaviour ------------------------------------------------------------------------
# jq_true <case-name> <file> <jq-filter that must yield true>. The VPS template is plain JSON (its
# ${VAR} placeholders all sit inside strings), so jq reads it directly.
jq_true() {
  local name="$1" file="$2" filter="$3"
  if jq -e "$filter" "$file" >/dev/null 2>&1; then ok "$name"; else ko "$name (jq: $filter)"; fi
}

# The VPS has no IPv6 route: resolve and dial IPv4 only, including the Reality handshake target.
jq_true vps_dns_ipv4_only "$VPS_TPL" '.dns.strategy == "ipv4_only"'
jq_true vps_direct_outbound_ipv4_only "$VPS_TPL" \
  '[.outbounds[] | select(.tag == "direct") | .domain_strategy] == ["ipv4_only"]'
jq_true vps_reality_handshake_ipv4_only "$VPS_TPL" \
  '[.inbounds[] | select(.tag == "vless-reality-in") | .tls.reality.handshake.domain_strategy] == ["ipv4_only"]'
# Every DNS server is reachable from `final` or a rule (sing-box never queries an orphan server).
jq_true vps_no_orphan_dns_servers "$VPS_TPL" \
  '[.dns.servers[].tag] - [.dns.final] - [(.dns.rules // [])[].server] == []'

# Log verbosity is chosen at deploy time and defaults to info, never committed as debug.
jq_true vps_log_level_is_a_deploy_variable "$VPS_TPL" '.log.level == "${SINGBOX_LOG_LEVEL}"'
if grep -qE 'SINGBOX_LOG_LEVEL="\$\{SINGBOX_LOG_LEVEL:-info\}"' "$REPO_ROOT/vps/bootstrap.sh"; then
  ok vps_log_level_defaults_to_info
else
  ko "vps_log_level_defaults_to_info (bootstrap.sh does not default SINGBOX_LOG_LEVEL to info)"
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]

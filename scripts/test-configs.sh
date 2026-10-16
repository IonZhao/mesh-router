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

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]

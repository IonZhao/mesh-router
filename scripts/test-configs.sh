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
if [[ -n "${KEEP_TEST_TMP:-}" ]]; then echo "keeping $TMP"; else trap 'rm -rf "$TMP"' EXIT; fi
pass=0
fail=0

# Prerequisites first: a missing tool must read as "missing tool", not as a failing case.
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
missing=""
if [[ -z "$(find_singbox)" ]] && ! { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }; then
  missing+=" sing-box $(pinned_singbox_version) (unpack it under .tools/, set SINGBOX_BIN, or start Docker);"
fi
[[ -z "$(find_mihomo)" ]] && missing+=" mihomo (set MIHOMO_BIN or put it on PATH);"
for t in jq openssl curl awk; do command -v "$t" >/dev/null 2>&1 || missing+=" $t;"; done
if [[ -n "$missing" ]]; then
  echo "FAIL prerequisites missing:$missing see README \"Validating locally\""
  exit 1
fi

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

# --- repository hygiene ---------------------------------------------------------------------------
# The repo is public: the deployment's own host, domains and the author's home paths must never be
# committed — neither in tracked files nor anywhere in this branch's history. Values are read from
# the local secrets file (when present) and never printed.
hygiene() {
  local envf="$REPO_ROOT/secrets/vps.env" vals=() v hits base="" found=0
  if [[ -f "$envf" ]]; then
    for v in VPS_HOST STATIC_DOMAIN CDN_DOMAIN; do
      val="$(grep -E "^$v=" "$envf" | head -1 | cut -d= -f2 | awk '{print $1}')"
      case "$val" in ""|*example*|203.0.113.*|cdn.invalid) ;; *) vals+=("$val") ;; esac
    done
    # the registrable domain behind STATIC_DOMAIN (static.<domain>) catches every subdomain
    val="$(grep -E '^STATIC_DOMAIN=' "$envf" | head -1 | cut -d= -f2 | awk '{print $1}')"
    [[ "$val" == *.*.* && "$val" != *example* ]] && vals+=("${val#*.}")
  fi
  # home-folder paths, split in two so this file does not match itself
  vals+=("C:\\""Users\\" "C:/""Users/" "/c/""Users/")
  base="$(git -C "$REPO_ROOT" merge-base HEAD origin/main 2>/dev/null || true)"
  for v in "${vals[@]}"; do
    hits="$(git -C "$REPO_ROOT" grep -l -I -F -e "$v" -- . 2>/dev/null | tr '\n' ' ')"
    if [[ -n "$hits" ]]; then ko "no_deployment_identifiers_tracked (a private value appears in: $hits)"; found=1; fi
    # no `grep -q`: it exits on the first match, git log dies of SIGPIPE and pipefail hides the hit
    if [[ -n "$base" ]] && git -C "$REPO_ROOT" log -p "$base..HEAD" | grep -F -e "$v" >/dev/null; then
      ko "no_deployment_identifiers_in_branch_history (a private value appears in a commit since $(echo "$base" | cut -c1-7))"
      found=1
    fi
  done
  [[ $found -eq 0 ]] && ok no_deployment_identifiers_tracked_or_in_history

  # Every committed script except the sourced lib.sh must be executable (README runs them on Linux).
  hits="$(git -C "$REPO_ROOT" ls-files -s -- '*.sh' | awk '$1 != "100755" && $4 != "scripts/lib.sh" {print $4}' | tr '\n' ' ')"
  if [[ -z "$hits" ]]; then ok scripts_are_executable_in_git; else ko "scripts_are_executable_in_git (not 100755: $hits)"; fi
}
hygiene

# --- the real templates pass every available check -------------------------------------------
expect 0 templates_validate "" env MESH_VALIDATE_LOG_DIR="$TMP/validate-logs" bash "$V"
# The start test must stay on this machine: no Let's Encrypt account or order for the throwaway
# values, no GitHub download gating "sing-box started".
if [[ -f "$TMP/validate-logs/start.log" ]] && ! grep -qiE 'letsencrypt|github\.com|acme-v02' "$TMP/validate-logs/start.log"; then
  ok vps_start_test_touches_no_public_service
else
  ko "vps_start_test_touches_no_public_service ($(grep -ciE 'letsencrypt|github\.com|acme-v02' "$TMP/validate-logs/start.log" 2>/dev/null || echo 'no log') matching lines)"
fi

# --- the harness catches what it claims to catch -------------------------------------------------
# sing-box rejects an invalid enum value in the VPS config.
sed -E 's/"strategy": "[a-z0-9_]+"/"strategy": "not_a_strategy"/' "$VPS_TPL" >"$TMP/bad-value.json.template"
expect 1 vps_invalid_value_rejected "FAIL vps: sing-box check" \
  env VPS_TEMPLATE="$TMP/bad-value.json.template" bash "$V" --vps

# A template variable that bootstrap.sh would not substitute is caught before deploy.
sed -E 's/"tag": "direct"/"tag": "${NOT_IN_BOOTSTRAP_VARS}"/' "$VPS_TPL" >"$TMP/unknown-var.json.template"
expect 1 vps_unrendered_variable_rejected "not substituted by bootstrap.sh VARS: NOT_IN_BOOTSTRAP_VARS" \
  env VPS_TEMPLATE="$TMP/unknown-var.json.template" bash "$V" --vps

# A config that passes `check` but dies at start is caught too: since 1.12 a DNS server whose
# detour is a plain direct outbound is refused only when services start (found in the 1.14.3 dry
# run on the VPS, 2026-10-19).
jq '.dns.servers[0].detour = "direct"' "$VPS_TPL" >"$TMP/dies-at-start.json.template"
expect 1 vps_config_that_dies_at_start_rejected "FAIL vps: sing-box did not start" \
  env VPS_TEMPLATE="$TMP/dies-at-start.json.template" bash "$V" --vps

# The Docker fallback must hand Docker paths its daemon can see: on a Windows host (Docker Desktop
# + Git Bash) that means native drive paths, not Git Bash's /tmp. A stand-in `docker` checks the
# -v sources the way Docker Desktop would resolve them.
stub="$TMP/stub-bin"
mkdir -p "$stub"
cat >"$stub/docker" <<'STUB'
#!/usr/bin/env bash
# Stateful stand-in: a container "exists" only after a `run -d` whose mounts passed the checks
# (marker file under $STUB_STATE); `logs`/`inspect` answer positively only for it; STUB_FAIL_START=1
# makes every `run -d` fail the way a real daemon refuses a bad mount or a taken name.
state="${STUB_STATE:-/tmp/stub-docker-state}"; mkdir -p "$state"
[[ "$1" == "info" ]] && exit 0
[[ "$1" == "logs" ]] && { [[ -f "$state/started" ]] && { echo "sing-box started"; exit 0; }; echo "stub-docker: no such container"; exit 1; }
[[ "$1" == "inspect" ]] && { [[ -f "$state/started" ]] && { echo true; exit 0; }; exit 1; }
[[ "$1" == "rm" ]] && { rm -f "$state/started"; exit 0; }
[[ "$1" == "run" ]] || exit 2
shift
detached=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-v" ]]; then
    if [[ "$2" =~ ^([A-Za-z]:/[^:]*):(/.*)$ ]]; then src="${BASH_REMATCH[1]}"
    elif [[ "$2" =~ ^(/[^:]*):(/.*)$ ]]; then src="${BASH_REMATCH[1]}"
    else echo "stub-docker: unparsable mount $2"; exit 1; fi
    if command -v cygpath >/dev/null 2>&1 && [[ ! "$src" =~ ^[A-Za-z]:/ ]]; then
      echo "stub-docker: Docker Desktop cannot see $src"; exit 1
    fi
    [[ -e "$src" ]] || { echo "stub-docker: missing $src"; exit 1; }
    shift 2
  else
    [[ "$1" == "-d" ]] && detached=1
    shift
  fi
done
if [[ -n "$detached" ]]; then
  [[ -n "${STUB_FAIL_START:-}" ]] && { echo "stub-docker: Error response from daemon: cannot start"; exit 125; }
  touch "$state/started"
fi
echo "stub-docker: ok"
STUB
chmod +x "$stub/docker"
expect 0 vps_docker_fallback_uses_daemon_visible_paths "sing-box starts with the rendered config \(docker" \
  env SINGBOX_USE_DOCKER=1 PATH="$stub:$PATH" STUB_STATE="$TMP/stub-state" bash "$V" --vps
# A container that fails to start is a FAIL, not a pass on a stale log.
expect 1 vps_docker_start_failure_is_reported "could not start the container" \
  env SINGBOX_USE_DOCKER=1 PATH="$stub:$PATH" STUB_STATE="$TMP/stub-state-fail" STUB_FAIL_START=1 bash "$V" --vps

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
# Since sing-box 1.12 that is one place: the route's default domain resolver (the Dial Field
# `domain_strategy` is gone in 1.14), plus dns.strategy for the DNS answers themselves.
jq_true vps_dns_ipv4_only "$VPS_TPL" '.dns.strategy == "ipv4_only"'
jq_true vps_default_domain_resolver_ipv4_only "$VPS_TPL" \
  '(.route.default_domain_resolver.strategy == "ipv4_only") and ((.route.default_domain_resolver.server) as $s | [.dns.servers[].tag] | index($s) != null)'
# Config schema of sing-box 1.12+/1.14: typed DNS servers, no legacy inbound sniff fields, no Dial
# Field domain_strategy, no inline ACME (certificate providers instead), sniffing as a route action.
jq_true vps_dns_servers_in_1_12_format "$VPS_TPL" \
  '[.dns.servers[] | has("type") and (has("address") | not)] | all'
jq_true vps_no_legacy_fields "$VPS_TPL" \
  '[.. | objects | (has("domain_strategy") or has("sniff") or has("sniff_override_destination") or has("acme"))] | any | not'
jq_true vps_sniff_is_the_first_route_action "$VPS_TPL" '.route.rules[0].action == "sniff"'
jq_true vps_hy2_cert_comes_from_an_acme_provider "$VPS_TPL" \
  '([.certificate_providers[]? | select(.type == "acme") | .tag]) as $t | [.inbounds[] | select(.tag == "hy2-in") | .tls.certificate_provider] | length == 1 and inside($t)'
# Every DNS server is reachable from `final` or a rule (sing-box never queries an orphan server).
jq_true vps_no_orphan_dns_servers "$VPS_TPL" \
  '[.dns.servers[].tag] - [.dns.final] - [(.dns.rules // [])[].server] == []'
# bootstrap.sh validates with the version pinned in .env, not a literal of its own, and no script
# carries a sing-box image tag of its own. The replay runs without the tester's SINGBOX_VERSION.
pin_line="$(grep -E '^SINGBOX_VERSION=' "$REPO_ROOT/vps/bootstrap.sh" | head -1)"
got="$(cd "$REPO_ROOT" && env -u SINGBOX_VERSION REPO_ROOT="$REPO_ROOT" bash -c "source scripts/lib.sh; $pin_line; printf '%s' \"\${SINGBOX_VERSION:-}\"" 2>/dev/null)"
literals="$(grep -lE 'sing-box:v[0-9]' "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/vps/*.sh 2>/dev/null | tr '\n' ' ')"
if [[ -n "$pin_line" && "$got" == "$(pinned_singbox_version)" && -z "$literals" ]]; then
  ok vps_bootstrap_checks_with_the_pinned_version
else
  ko "vps_bootstrap_checks_with_the_pinned_version (bootstrap resolves '$got', .env pins '$(pinned_singbox_version)', literal tags in: ${literals:-none})"
fi
# The pin parser tolerates what docker compose tolerates: quotes, a trailing comment, CRLF.
pin_probe="$TMP/pin-probe"; mkdir -p "$pin_probe/scripts"; cp "$SCRIPT_DIR/lib.sh" "$pin_probe/scripts/"
printf 'SINGBOX_VERSION="v9.9.9"   # pinned\r\n' >"$pin_probe/.env"
if [[ "$(bash -c "source '$pin_probe/scripts/lib.sh'; pinned_singbox_version")" == "v9.9.9" ]]; then ok pin_parser_strips_quotes_comment_and_cr
else ko "pin_parser_strips_quotes_comment_and_cr (got '$(bash -c "source '$pin_probe/scripts/lib.sh'; pinned_singbox_version")')"; fi
: >"$pin_probe/.env"
if ! bash -c "source '$pin_probe/scripts/lib.sh'; pinned_singbox_version" >/dev/null 2>&1; then ok pin_parser_fails_on_missing_pin
else ko "pin_parser_fails_on_missing_pin"; fi

# mac-auto prefers the Mac: urltest only leaves its current pick when another outbound is faster
# by more than `tolerance`, and the always-faster direct must not win by a few hundred ms.
jq_true vps_mac_auto_prefers_mac "$VPS_TPL" \
  '[.outbounds[] | select(.tag == "mac-auto") | (.outbounds[0] == "mac-out" and .tolerance >= 1000)] == [true]'

# Log verbosity is chosen at deploy time and defaults to info, never committed as debug.
jq_true vps_log_level_is_a_deploy_variable "$VPS_TPL" '.log.level == "${SINGBOX_LOG_LEVEL}"'
if grep -qE 'SINGBOX_LOG_LEVEL="\$\{SINGBOX_LOG_LEVEL:-info\}"' "$REPO_ROOT/vps/bootstrap.sh"; then
  ok vps_log_level_defaults_to_info
else
  ko "vps_log_level_defaults_to_info (bootstrap.sh does not default SINGBOX_LOG_LEVEL to info)"
fi

# --- Reality handshake-target checker (fixtures = saved `openssl s_client -msg` output) -----------
R="$SCRIPT_DIR/check-reality-target.sh"
TD="$SCRIPT_DIR/testdata"
# Small records, TLS 1.3 + h2 + X25519; a 0x2100-byte NewSessionTicket AFTER the handshake must not count.
expect 0 reality_target_ok_passes "PASS" \
  env CHECK_REALITY_INPUT="$TD/reality-target-ok.msg" bash "$R" example.test
# One server record over REALITY's limit (5-byte header + length > 8192) is a hard failure.
expect 1 reality_target_oversized_record_fails "record 8273 bytes" \
  env CHECK_REALITY_INPUT="$TD/reality-target-big-record.msg" bash "$R" example.test
# The whole server flight above 8192 bytes can overflow REALITY's buffer between reads.
expect 1 reality_target_oversized_flight_fails "flight 8464 bytes" \
  env CHECK_REALITY_INPUT="$TD/reality-target-big-flight.msg" bash "$R" example.test
# OpenSSL 3.5+ reports the TLS 1.3 key exchange as "Negotiated TLS1.3 group:" instead of
# "Server Temp Key:"; the checker must not FAIL every target on such a VPS.
sed 's/^Server Temp Key: X25519, 253 bits$/Negotiated TLS1.3 group: X25519/' "$TD/reality-target-ok.msg" >"$TMP/openssl35.msg"
expect 0 reality_target_newer_openssl_wording_passes "PASS" \
  env CHECK_REALITY_INPUT="$TMP/openssl35.msg" bash "$R" example.test
# REALITY targets must negotiate h2.
expect 1 reality_target_without_h2_fails "no h2" \
  env CHECK_REALITY_INPUT="$TD/reality-target-no-h2.msg" bash "$R" example.test

# --- client behaviour, as mihomo itself sees it ---------------------------------------------------
# Render the client template with throwaway values, point every remote rule set at an unreachable
# URL with an empty rules/ dir (a first start with no mirror reachable), run it in an isolated mihomo
# and ask mihomo what it built and which rule each sample domain hits.
client_runtime() {
  local bin work api="127.0.0.1:17891" port="17890" pid i
  # shellcheck source=lib.sh
  source "$SCRIPT_DIR/lib.sh"
  bin="$(find_mihomo)"
  if [[ -z "$bin" ]]; then ko "client_runtime (no mihomo binary; set MIHOMO_BIN)"; return; fi
  work="$TMP/client-rt"
  mkdir -p "$work/rules"
  write_throwaway_env "$TMP/client.env"
  if ! MESH_SECRETS_FILES="$TMP/client.env" MESH_CLIENT_OUT="$work/rendered.yaml" MESH_SKIP_RULE_DOWNLOAD=1 \
       bash "$REPO_ROOT/client/render-client-config.sh" >"$work/render.log" 2>&1; then
    ko "client_runtime (render failed)"; tail -3 "$work/render.log"; return
  fi
  awk -v port="$port" '
    /^[A-Za-z][A-Za-z0-9-]*:/ { section = $1 }
    /^mixed-port:/ { print "mixed-port: " port; next }
    /^log-level:/  { print "log-level: info"; next }
    section == "rule-providers:" && /^[[:space:]]+url:/ { sub(/url:.*/, "url: http://127.0.0.1:9/unreachable") }
    { print }
  ' "$work/rendered.yaml" >"$work/config.yaml"
  printf 'external-controller: %s\n' "$api" >>"$work/config.yaml"
  seed_geo_files "$bin" "$work"

  timeout 90 "$bin" -d "$(cygpath -m "$work" 2>/dev/null || echo "$work")" \
    -f "$(cygpath -m "$work/config.yaml" 2>/dev/null || echo "$work/config.yaml")" >"$work/mihomo.log" 2>&1 &
  pid=$!
  for i in $(seq 1 40); do
    curl -s -o /dev/null --noproxy '*' --max-time 1 "http://$api/version" && break
    sleep 0.5
  done
  if ! curl -s -o /dev/null --noproxy '*' --max-time 1 "http://$api/version"; then
    ko "client_runtime (mihomo did not start)"; tail -5 "$work/mihomo.log" | sed 's/^/    /'
    kill "$pid" 2>/dev/null; return
  fi

  curl -s --noproxy '*' "http://$api/proxies/PROXY" >"$work/group.json"
  curl -s --noproxy '*' "http://$api/providers/rules" >"$work/providers.json"
  jq_true client_group_is_fallback_hy2_first "$work/group.json" \
    '.type == "Fallback" and .all == ["hy2-vps", "reality-vps", "cdn-fallback"]'
  jq_true client_group_requires_http_204 "$work/group.json" '.expectedStatus == "204"'
  jq_true client_rule_providers_loaded "$work/providers.json" \
    '(.providers | keys) as $k | ["ads", "cn-domain", "cn-ip", "direct-extra"] - $k == []'

  # mihomo holds connections for a few seconds while rule providers are still initialising
  # (measured: ~1-6 s with unreachable URLs and no cached files); wait until it routes traffic.
  for i in $(seq 1 60); do
    curl -s -o /dev/null --max-time 4 -x "http://127.0.0.1:$port" "http://www.baidu.com/" || true
    grep -q 'www\.baidu\.com' "$work/mihomo.log" && break
    sleep 0.5
  done
  # 223.5.5.5 = AliDNS, a CN IP reached without any hostname (like WeChat's hard-coded IPs).
  for host in mirrors.tuna.tsinghua.edu.cn www.example.com 223.5.5.5; do
    curl -s -o /dev/null --max-time 8 -x "http://127.0.0.1:$port" "http://$host/" || true
  done
  sleep 1
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  rule_hit() {  # rule_hit <case> <host> <rule-regex>
    if grep -qE "$2:80 match $3|match ${3//\(/\/}.*$2:80|\($3\).*$2:80|$2:80.*$3" "$work/mihomo.log"; then ok "$1"
    else ko "$1 ($2 did not hit /$3/)"; grep -E "$2" "$work/mihomo.log" | tail -2 | sed 's/^/    /'; fi
  }
  rule_hit client_override_list_wins mirrors.tuna.tsinghua.edu.cn 'RuleSet.direct-extra'
  rule_hit client_cn_stays_direct_without_rule_sets www.baidu.com 'GeoSite.cn'
  rule_hit client_foreign_goes_to_proxy www.example.com 'Match'
  rule_hit client_cn_ip_stays_direct_without_rule_sets '223\.5\.5\.5' 'GeoIP.[Cc][Nn]'   # mihomo logs "GeoIP(cn)"
}
client_runtime

# --- render-client-config.sh pre-downloads the remote rule sets ------------------------------------
render_preseed() {
  local work="$TMP/preseed" fixture url
  mkdir -p "$work"
  # shellcheck source=lib.sh
  source "$SCRIPT_DIR/lib.sh"
  write_throwaway_env "$TMP/preseed.env"
  fixture="$SCRIPT_DIR/testdata/reality-target-ok.msg"            # any file will do as a payload
  url="file://$(cygpath -m "$fixture" 2>/dev/null | sed 's#^#/#' || echo "$fixture")"
  # Every remote rule set reachable (as a local file) -> each lands under rules/ in the rules dir.
  awk -v u="$url" '/^[A-Za-z]/{s=$1} s=="rule-providers:" && /^[[:space:]]+url:/{sub(/url:.*/, "url: " u)} {print}' \
    "$CLIENT_TPL" >"$work/ok.template"
  expect 0 render_preseeds_rule_sets "downloaded: rules/cn-domain.mrs" \
    env MESH_SECRETS_FILES="$TMP/preseed.env" MESH_CLIENT_TPL="$work/ok.template" \
        MESH_CLIENT_OUT="$work/ok.yaml" MESH_RULES_DIR="$work/ok" bash "$REPO_ROOT/client/render-client-config.sh"
  if cmp -s "$fixture" "$work/ok/rules/cn-domain.mrs" && cmp -s "$fixture" "$work/ok/rules/ads.mrs"; then
    ok render_preseed_files_match_source
  else
    ko "render_preseed_files_match_source (rules/ under $work/ok missing or different)"
  fi
  # Every remote rule set unreachable -> the render still succeeds and only warns.
  awk '/^[A-Za-z]/{s=$1} s=="rule-providers:" && /^[[:space:]]+url:/{sub(/url:.*/, "url: http://127.0.0.1:9/unreachable")} {print}' \
    "$CLIENT_TPL" >"$work/down.template"
  expect 0 render_survives_unreachable_rule_sets "WARN: could not download" \
    env MESH_SECRETS_FILES="$TMP/preseed.env" MESH_CLIENT_TPL="$work/down.template" \
        MESH_CLIENT_OUT="$work/down.yaml" MESH_RULES_DIR="$work/down" bash "$REPO_ROOT/client/render-client-config.sh"
  # A secrets file under a path with a space (a home folder named "First Last") still loads.
  mkdir -p "$work/dir with space"
  cp "$TMP/preseed.env" "$work/dir with space/vps.env"
  expect 0 render_loads_secrets_from_path_with_space "Wrote " \
    env MESH_SECRETS_FILES="$work/dir with space/vps.env" MESH_SKIP_RULE_DOWNLOAD=1 \
        MESH_CLIENT_OUT="$work/space.yaml" bash "$REPO_ROOT/client/render-client-config.sh"
}
render_preseed

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]

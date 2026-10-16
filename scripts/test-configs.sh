#!/usr/bin/env bash
# Test suite for the config templates and the local tooling. No real secrets are read except, in
# the hygiene check, to make sure none of them is committed. Remote rule-set mirrors are never
# needed: the runtime cases point providers at unreachable URLs and still pass when the few public
# hosts they dial (baidu, tuna) are unreachable. Needs a mihomo binary and a sing-box binary (or
# Docker); see scripts/validate-configs.sh for how they are found.
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
if [[ -n "${SINGBOX_USE_DOCKER:-}" ]]; then
  docker_up || missing+=" Docker (SINGBOX_USE_DOCKER=1 is set but docker is not running);"
elif [[ -z "$(find_singbox)" ]] && ! docker_up; then
  missing+=" sing-box $(pinned_singbox_version) (unpack .tools/sing-box-<version>-$(host_platform)/, set SINGBOX_BIN, or start Docker);"
fi
[[ -z "$(find_mihomo)" ]] && missing+=" mihomo (set MIHOMO_BIN or MESH_CLASH_VERGE_DIR, or put mihomo on PATH);"
for t in jq openssl curl awk envsubst timeout; do command -v "$t" >/dev/null 2>&1 || missing+=" $t;"; done
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
# Print every private value from a secrets file that must never appear in the repo: hosts, domains
# (plus the registrable domain behind STATIC_DOMAIN), UUIDs, passwords, keys, tokens. Placeholders
# from the *.example files are skipped. Values are only compared, never printed by the suite.
hygiene_values_from() {
  local envf="$1" v val tok
  [[ -f "$envf" ]] || return 0
  for v in VPS_HOST STATIC_DOMAIN CDN_DOMAIN ACME_EMAIL MAC_TAILSCALE_IP VLESS_UUID MAC_VLESS_UUID \
           HY2_PASSWORD HY2_OBFS_PASSWORD REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID \
           CLASH_API_SECRET CDN_WS_PATH TS_AUTHKEY KUMA_PUSH_URL_SINGBOX; do
    # value = everything after the first "=", minus quotes, a trailing "# comment" and CR
    val="$(grep -E "^$v=" "$envf" | head -1 | cut -d= -f2- | sed 's/[[:space:]]#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//' | tr -d '\r"'"'")"
    case "$val" in
      ""|*example*|203.0.113.*|cdn.invalid|100.x.*|change-me|changemechangeme|0123456789abcdef| \
      00000000-0000-0000-0000-000000000000|tskey-auth-xxxxxxxxxxxx) continue ;;
    esac
    [[ ${#val} -ge 6 ]] || continue   # a 2-4 character value would match by chance all over the history
    if [[ "$v" == KUMA_PUSH_URL_SINGBOX ]]; then
      val="${val%%\?*}"; tok="${val##*/}"
      printf '%s\n' "$val"; [[ ${#tok} -ge 6 ]] && printf '%s\n' "$tok"
      continue
    fi
    printf '%s\n' "$val"
    if [[ "$v" == STATIC_DOMAIN && "$val" == *.*.* ]]; then printf '%s\n' "${val#*.}"; fi
  done
}

hygiene() {
  local vals=() v hits base="" found=0 envf
  for envf in vps.env mac.env; do
    while IFS= read -r v; do [[ -n "$v" ]] && vals+=("$v"); done < <(hygiene_values_from "$REPO_ROOT/secrets/$envf")
  done
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

  # The value list must cover every secret the templates carry, not only hosts and domains.
  local probe_env="$TMP/hygiene-probe.env" out
  cat >"$probe_env" <<'EOF'
VPS_HOST=198.51.100.7                      # comment
STATIC_DOMAIN=static.hygiene-probe.test
CDN_DOMAIN=cdn.example.com
VLESS_UUID=0f1e2d3c-4b5a-4968-8777-66554433aabb
MAC_VLESS_UUID=11111111-2222-4333-8444-555555555555
HY2_PASSWORD=hy2probepass
HY2_OBFS_PASSWORD=obfsprobepass
REALITY_PRIVATE_KEY=cHJvYmUtcHJpdmF0ZS1rZXktcHJvYmUtcHJpdmF0ZQ
REALITY_SHORT_ID=feedfacecafebeef
CLASH_API_SECRET=clashprobesecret
CDN_WS_PATH=wsprobepath
TS_AUTHKEY=tskey-auth-probe123
ACME_EMAIL=probe@hygiene-probe.test
MAC_TAILSCALE_IP=100.101.102.103
REALITY_PUBLIC_KEY="cHJvYmUtcHVibGljLWtleS1wcm9iZS1wdWJsaWM"     # quoted, with a comment
KUMA_PUSH_URL_SINGBOX="http://198.51.100.9:3001/api/push/kumaprobetoken?status=up&msg=OK&ping="
EOF
  out="$(hygiene_values_from "$probe_env" 2>/dev/null | tr '\n' ' ')"
  local want missing_vals=""
  for want in 198.51.100.7 static.hygiene-probe.test hygiene-probe.test 0f1e2d3c-4b5a-4968-8777-66554433aabb \
              11111111-2222-4333-8444-555555555555 hy2probepass obfsprobepass \
              cHJvYmUtcHJpdmF0ZS1rZXktcHJvYmUtcHJpdmF0ZQ feedfacecafebeef clashprobesecret wsprobepath tskey-auth-probe123 \
              probe@hygiene-probe.test 100.101.102.103 cHJvYmUtcHVibGljLWtleS1wcm9iZS1wdWJsaWM \
              http://198.51.100.9:3001/api/push/kumaprobetoken kumaprobetoken; do
    [[ " $out " == *" $want "* ]] || missing_vals+=" $want"
  done
  if [[ -z "$missing_vals" && " $out " != *" cdn.example.com "* && "$out" != *'?status=up'* ]]; then ok hygiene_scans_every_secret_value
  else ko "hygiene_scans_every_secret_value (missing:$missing_vals; placeholders kept: $([[ " $out " == *" cdn.example.com "* ]] && echo yes || echo no))"; fi
  # Very short values (a 2-character Reality short id) would match by chance; they are skipped.
  printf 'REALITY_SHORT_ID=ab\nVLESS_UUID=0f1e2d3c-4b5a-4968-8777-66554433aabb\n' >"$probe_env.short"
  out="$(hygiene_values_from "$probe_env.short" 2>/dev/null | tr '\n' ' ')"
  if [[ " $out " == *" 0f1e2d3c-4b5a-4968-8777-66554433aabb "* && " $out " != *" ab "* ]]; then ok hygiene_skips_values_too_short_to_scan
  else ko "hygiene_skips_values_too_short_to_scan (got: $out)"; fi

  # Every committed script except the sourced lib.sh must be executable (README runs them on Linux).
  hits="$(git -C "$REPO_ROOT" ls-files -s -- '*.sh' | awk '$1 != "100755" && $4 != "scripts/lib.sh" {print $4}' | tr '\n' ' ')"
  if [[ -z "$hits" ]]; then ok scripts_are_executable_in_git; else ko "scripts_are_executable_in_git (not 100755: $hits)"; fi
}
hygiene

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

# The Docker fallback must hand Docker paths its daemon can see: on a Windows host (Docker Desktop
# + Git Bash) that means native drive paths, not Git Bash's /tmp. A stand-in `docker` checks the
# -v sources the way Docker Desktop would resolve them.
stub="$TMP/stub-bin"
mkdir -p "$stub"
cat >"$stub/docker" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "info" ]] && exit 0
[[ "$1" == "run" ]] || exit 2
shift
mounts=0; image=""; rest=()
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-v" ]]; then
    if [[ "$2" =~ ^([A-Za-z]:/[^:]*):(/.*)$ ]]; then src="${BASH_REMATCH[1]}"
    elif [[ "$2" =~ ^(/[^:]*):(/.*)$ ]]; then src="${BASH_REMATCH[1]}"
    else echo "stub-docker: unparsable mount $2"; exit 1; fi
    if command -v cygpath >/dev/null 2>&1 && [[ ! "$src" =~ ^[A-Za-z]:/ ]]; then
      echo "stub-docker: Docker Desktop cannot see $src"; exit 1
    fi
    [[ -e "$src" ]] || { echo "stub-docker: missing $src"; exit 1; }
    mounts=$((mounts + 1)); shift 2
  elif [[ "$1" == --* ]]; then
    shift
  elif [[ -z "$image" ]]; then
    image="$1"; shift
  else
    rest+=("$1"); shift
  fi
done
[[ "$image" =~ ^ghcr.io/sagernet/sing-box:.+$ ]] || { echo "stub-docker: empty image tag in '$image'"; exit 1; }
[[ "$mounts" -eq 3 ]] || { echo "stub-docker: expected 3 mounts, got $mounts"; exit 1; }
[[ "${rest[*]}" == "check -c /c.json" ]] || { echo "stub-docker: expected 'check -c /c.json', got '${rest[*]}'"; exit 1; }
echo "stub-docker: ok"
STUB
chmod +x "$stub/docker"
expect 0 vps_docker_fallback_uses_daemon_visible_paths "sing-box check passed \(docker" \
  env SINGBOX_USE_DOCKER=1 PATH="$stub:$PATH" bash "$V" --vps
# The stand-in itself must be strict, or the case above could pass for the wrong reason.
NT="$(native "$TMP")"
expect 1 stub_docker_rejects_empty_image_tag "empty image tag" \
  "$stub/docker" run --rm -v "$NT:/a:ro" -v "$NT:/b:ro" -v "$NT:/c:ro" "ghcr.io/sagernet/sing-box:" check -c /c.json
expect 1 stub_docker_requires_three_mounts_and_check "expected 3 mounts" \
  "$stub/docker" run --rm -v "$NT:/a:ro" "ghcr.io/sagernet/sing-box:v1.11.14" check -c /c.json

# SINGBOX_USE_DOCKER=1 with Docker down is a hard failure that names Docker, never a WARN + exit 0.
stubdown="$TMP/stub-down"
mkdir -p "$stubdown"
printf '#!/usr/bin/env bash\nexit 1\n' >"$stubdown/docker"
chmod +x "$stubdown/docker"
expect 1 vps_use_docker_without_daemon_fails "Docker is not running" \
  env SINGBOX_USE_DOCKER=1 PATH="$stubdown:$PATH" bash "$V" --vps

# No SINGBOX_VERSION pin → hard failure, not an empty image tag.
expect 1 vps_missing_version_pin_fails "SINGBOX_VERSION" \
  env MESH_ENV_FILE="$TMP/no-such.env" bash "$V" --vps

# A sing-box of another version still checks, but warns that it is not what the VPS runs.
stubsb="$TMP/stub-sb"
mkdir -p "$stubsb"
printf '#!/usr/bin/env bash\n[[ "$1" == version ]] && { echo "sing-box version 9.9.9"; exit 0; }\nexit 0\n' >"$stubsb/sing-box"
chmod +x "$stubsb/sing-box"
expect 0 vps_singbox_version_mismatch_warns "WARN vps: sing-box 9.9.9 found but .env pins" \
  env SINGBOX_BIN="$stubsb/sing-box" bash "$V" --vps

# Binary discovery: the pinned version for THIS host platform, never a pre-release or another arch.
discovery() {
  local plat other tools pin exe=""
  plat="$(host_platform)"
  case "$plat" in *-amd64) other="${plat%-amd64}-arm64" ;; *) other="${plat%-*}-amd64" ;; esac
  [[ "$plat" == windows-* ]] && exe=".exe"
  pin="$(pinned_singbox_version)"; pin="${pin#v}"
  tools="$TMP/tools"
  for d in "sing-box-$pin-beta.1-$plat" "sing-box-$pin-$plat" "sing-box-$pin-$other"; do
    mkdir -p "$tools/$d"
    printf '#!/usr/bin/env bash\necho "sing-box version %s"\n' "$pin" >"$tools/$d/sing-box$exe"
    chmod +x "$tools/$d/sing-box$exe"
  done
  local got
  got="$(SINGBOX_BIN= MESH_TOOLS_DIR="$tools" find_singbox)"
  if [[ "$got" == "$tools/sing-box-$pin-$plat/sing-box$exe" ]]; then ok find_singbox_picks_exact_version_for_host
  else ko "find_singbox_picks_exact_version_for_host (got '$got')"; fi

  mkdir -p "$TMP/pf/Clash Verge"
  printf '#!/usr/bin/env bash\n' >"$TMP/pf/Clash Verge/verge-mihomo.exe"
  chmod +x "$TMP/pf/Clash Verge/verge-mihomo.exe"
  got="$(MIHOMO_BIN= MESH_CLASH_VERGE_DIR= MESH_MIHOMO_NO_PROCESS=1 PROGRAMFILES="$TMP/pf" LOCALAPPDATA="$TMP/none" PATH=/nonexistent find_mihomo)"
  if [[ "$got" == "$TMP/pf/Clash Verge/verge-mihomo.exe" ]]; then ok find_mihomo_falls_back_to_program_files
  else ko "find_mihomo_falls_back_to_program_files (got '$got')"; fi
}
discovery

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
  local bin work api="127.0.0.1:17891" port="17890" pid i auth
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
  printf 'external-controller: %s\nsecret: rt-secret-17891\n' "$api" >>"$work/config.yaml"
  seed_geo_files "$bin" "$work"
  auth=(-H "Authorization: Bearer rt-secret-17891")

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

  curl -s --noproxy '*' "${auth[@]}" "http://$api/proxies/PROXY" >"$work/group.json"
  curl -s --noproxy '*' "${auth[@]}" "http://$api/providers/rules" >"$work/providers.json"
  curl -s --noproxy '*' "${auth[@]}" "http://$api/rules" >"$work/rules.json"

  # The client health check against a live controller: a wrong secret is "unreachable" (401 is not
  # data); the right one reads the group and its nodes. This instance's rule sets never load (their
  # URLs are unreachable), which the check reports as an alert (exit 1) — the group itself is fine.
  expect 2 health_live_controller_rejects_wrong_secret "status=unreachable" \
    env HEALTH_DIR="$work/health-bad" MIHOMO_API="$api" MIHOMO_SECRET=wrong-secret HEALTH_NOTIFY=echo bash "$REPO_ROOT/client/health-check.sh"
  expect 1 health_live_controller_reads_the_group "status=alert group=[a-z2-]+-(vps|fallback) nodes=hy2-vps:(alive|dead):[0-9]*;reality-vps:" \
    env HEALTH_DIR="$work/health-ok" MIHOMO_API="$api" MIHOMO_SECRET=rt-secret-17891 HEALTH_NOTIFY=echo bash "$REPO_ROOT/client/health-check.sh"
  grep -q 'NOTIFY: rule set ads has never been loaded' "$TMP/health_live_controller_reads_the_group.log" || ko "health_live_controller_reads_the_group (never-loaded rule set not reported)"
  # A false positive in the ad list must be correctable without sending the domain DIRECT:
  # an inline proxy-extra set sits before the ads REJECT rule.
  jq_true client_proxy_extra_precedes_ads "$work/rules.json" \
    '[.rules[].payload] | (index("proxy-extra") != null) and (index("proxy-extra") < index("ads"))'
  jq_true client_group_is_fallback_hy2_first "$work/group.json" \
    '.type == "Fallback" and .all == ["hy2-vps", "reality-vps", "cdn-fallback"]'
  jq_true client_group_requires_http_204 "$work/group.json" '.expectedStatus == "204"'
  jq_true client_rule_providers_loaded "$work/providers.json" \
    '(.providers | keys) as $k | ["ads", "cn-domain", "cn-ip", "direct-extra", "proxy-extra"] - $k == []'

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
  # A cached rule file older than a day is refreshed; a fresh one is left alone.
  mkdir -p "$work/stale/rules"
  printf 'old\n' >"$work/stale/rules/cn-domain.mrs"
  touch -d '2 days ago' "$work/stale/rules/cn-domain.mrs"
  printf 'keep\n' >"$work/stale/rules/ads.mrs"
  expect 0 render_refreshes_rule_sets_older_than_a_day "refreshed: +rules/cn-domain.mrs" \
    env MESH_SECRETS_FILES="$TMP/preseed.env" MESH_CLIENT_TPL="$work/ok.template" \
        MESH_CLIENT_OUT="$work/stale.yaml" MESH_RULES_DIR="$work/stale" bash "$REPO_ROOT/client/render-client-config.sh"
  if cmp -s "$fixture" "$work/stale/rules/cn-domain.mrs" && [[ "$(cat "$work/stale/rules/ads.mrs")" == "keep" ]]; then
    ok render_refresh_replaces_only_stale_files
  else
    ko "render_refresh_replaces_only_stale_files (stale not replaced, or fresh file touched)"
  fi

  # A secrets file under a path with a space (a home folder named "First Last") still loads.
  mkdir -p "$work/dir with space"
  cp "$TMP/preseed.env" "$work/dir with space/vps.env"
  expect 0 render_loads_secrets_from_path_with_space "Wrote " \
    env MESH_SECRETS_FILES="$work/dir with space/vps.env" MESH_SKIP_RULE_DOWNLOAD=1 \
        MESH_CLIENT_OUT="$work/space.yaml" bash "$REPO_ROOT/client/render-client-config.sh"
}
render_preseed

# --- scripts/singbox-log-alert.sh (VPS cron → Uptime Kuma) ---------------------------------------
A="$SCRIPT_DIR/singbox-log-alert.sh"
# IPv6 "network is unreachable" and a failed handshake-target dial are outages: status=down, exit 1.
expect 1 singbox_alert_down_on_unreachable "status=down unreachable=4 dial_dest=1 invalid=5 " \
  env SINGBOX_LOG_INPUT="$TD/singbox-log-bad.txt" bash "$A"
# Scanner noise alone (invalid Reality handshakes from strangers) is not an outage: status=up, exit 0.
expect 0 singbox_alert_up_on_scanner_noise_only "status=up unreachable=0 dial_dest=0 invalid=4 " \
  env SINGBOX_LOG_INPUT="$TD/singbox-log-ok.txt" bash "$A"
# A lower invalid-connection ceiling turns noise into an alert when the owner wants it.
expect 1 singbox_alert_invalid_ceiling_is_configurable "status=down" \
  env SINGBOX_LOG_INPUT="$TD/singbox-log-ok.txt" ALERT_INVALID_MAX=3 bash "$A"
# The Uptime Kuma push carries the status and the counts; the token in the URL is never printed.
expect 1 singbox_alert_pushes_status_and_counts "push: http://127\.0\.0\.1:9/api/push/\*\*\*\?status=down&msg=unreachable%3D4" \
  env SINGBOX_LOG_INPUT="$TD/singbox-log-bad.txt" KUMA_PUSH_URL="http://127.0.0.1:9/api/push/SECRETTOKEN" ALERT_DRY_RUN=1 bash "$A"
if grep -q SECRETTOKEN "$TMP/singbox_alert_pushes_status_and_counts.log" 2>/dev/null; then
  ko "singbox_alert_never_prints_push_token"
else
  ok singbox_alert_never_prints_push_token
fi
# Kuma shows the push URL with a "?status=up&msg=OK&ping=" tail; pasted as-is it must still push
# OUR status: the URL is used up to the token.
expect 1 singbox_alert_drops_pasted_query_from_push_url "push: http://127\.0\.0\.1:9/api/push/\*\*\*\?status=down&msg=unreachable%3D4" \
  env SINGBOX_LOG_INPUT="$TD/singbox-log-bad.txt" KUMA_PUSH_URL="http://127.0.0.1:9/api/push/SECRETTOKEN?status=up&msg=OK&ping=" ALERT_DRY_RUN=1 bash "$A"
grep -q 'status=up' "$TMP/singbox_alert_drops_pasted_query_from_push_url.log" 2>/dev/null && ko "singbox_alert_drops_pasted_query_from_push_url (pasted status=up survived)"
# Same when the URL comes from the secrets file, quoted and with a trailing comment.
printf 'KUMA_PUSH_URL_SINGBOX="http://127.0.0.1:9/api/push/SECRETTOKEN?status=up&msg=OK&ping="   # pasted from Kuma\n' >"$TMP/alert-secrets.env"
expect 1 singbox_alert_reads_quoted_url_from_secrets_file "push: http://127\.0\.0\.1:9/api/push/\*\*\*\?status=down&msg=unreachable%3D4" \
  env SINGBOX_LOG_INPUT="$TD/singbox-log-bad.txt" ALERT_SECRETS_FILE="$TMP/alert-secrets.env" ALERT_DRY_RUN=1 bash "$A"
grep -q SECRETTOKEN "$TMP/singbox_alert_reads_quoted_url_from_secrets_file.log" 2>/dev/null && ko "singbox_alert_reads_quoted_url_from_secrets_file (token printed)"

# --- client/health-check.sh (scheduled on the client; CSV + alerts) --------------------------------
H="$REPO_ROOT/client/health-check.sh"
T0=1792119600                                   # 2026-10-16 03:00:00 UTC
# health_fixture <dir> <PROXY now> <hy2> <reality> <cdn> <providers updatedAt>
# Node state: true | false | other-url (the node's overall .alive is true, but the result for the
# group's own test URL — .extra[testUrl].alive, what the fallback group actually acts on — is false).
# Shapes copied from mihomo v1.19.32's /proxies answers.
health_fixture() {
  local d="$1" spec n a u="https://www.gstatic.com/generate_204"
  mkdir -p "$d"
  jq -n --arg now "$2" --arg u "$u" '{alive:true,all:["hy2-vps","reality-vps","cdn-fallback"],extra:{},history:[],name:"PROXY",now:$now,type:"Fallback",udp:true,expectedStatus:"204",testUrl:$u}' >"$d/proxies-PROXY.json"
  for spec in "hy2-vps:$3" "reality-vps:$4" "cdn-fallback:$5"; do
    n="${spec%%:*}"; a="${spec##*:}"
    jq -n --arg n "$n" --arg a "$a" --arg u "$u" '
      ($a != "false") as $overall | ($a == "true") as $for_url |
      {alive:$overall, history:[{time:"2026-10-16T02:59:00Z",delay:(if $overall then 210 else 0 end)}],
       extra:{($u):{alive:$for_url, history:[{time:"2026-10-16T02:59:00Z",delay:(if $for_url then 210 else 0 end)}]}},
       name:$n, type:"X", udp:true}' >"$d/proxies-$n.json"
  done
  jq -n --arg t "$6" '{providers:{"cn-domain":{name:"cn-domain",ruleCount:111224,updatedAt:$t,vehicleType:"HTTP"},"cn-ip":{name:"cn-ip",ruleCount:8000,updatedAt:$t,vehicleType:"HTTP"},"ads":{name:"ads",ruleCount:100000,updatedAt:$t,vehicleType:"HTTP"},"direct-extra":{name:"direct-extra",ruleCount:1,updatedAt:$t,vehicleType:"Inline"}}}' >"$d/providers-rules.json"
}
hc() { # hc <state dir> <fixture dir> <now epoch>  (notifications are echoed, never toasted)
  env HEALTH_DIR="$1" HEALTH_API_FIXTURE_DIR="$2" HEALTH_NOW="$3" HEALTH_NOTIFY=echo bash "$H"
}
HD="$TMP/health"
health_fixture "$HD/good" hy2-vps true true true 2026-10-16T01:00:00Z
health_fixture "$HD/reality-dead" hy2-vps true false true 2026-10-16T01:00:00Z
health_fixture "$HD/on-cdn" cdn-fallback true true true 2026-10-16T01:00:00Z
health_fixture "$HD/stale-rules" hy2-vps true true true 2026-10-12T01:00:00Z
health_fixture "$HD/hy2-fails-group-url" hy2-vps other-url true true 2026-10-16T01:00:00Z
mkdir -p "$HD/no-api" "$HD/bad-auth"
echo '{"message":"Unauthorized"}' >"$HD/bad-auth/proxies-PROXY.json"

expect 0 health_ok_appends_csv_row "status=ok" hc "$HD/s1" "$HD/good" "$T0"
if [[ -f "$HD/s1/health.csv" && "$(wc -l <"$HD/s1/health.csv")" -eq 2 ]]; then ok health_csv_has_header_and_one_row
else ko "health_csv_has_header_and_one_row ($(wc -l <"$HD/s1/health.csv" 2>/dev/null || echo missing) lines)"; fi

# A dead node is not an alert until it has been dead for 10 minutes; then exactly one alert,
# then one "recovered" when it comes back.
expect 0 health_dead_node_under_10min_is_quiet "status=ok" hc "$HD/s2" "$HD/reality-dead" "$T0"
grep -q NOTIFY "$TMP/health_dead_node_under_10min_is_quiet.log" && ko "health_dead_node_under_10min_is_quiet (notified early)"
expect 1 health_dead_node_over_10min_alerts "NOTIFY: reality-vps has been dead for 11 min" hc "$HD/s2" "$HD/reality-dead" "$((T0 + 660))"
expect 1 health_dead_node_alert_not_repeated "status=alert" hc "$HD/s2" "$HD/reality-dead" "$((T0 + 960))"
grep -q NOTIFY "$TMP/health_dead_node_alert_not_repeated.log" && ko "health_dead_node_alert_not_repeated (repeated notification)"
expect 0 health_recovery_is_announced_once "NOTIFY: reality-vps recovered" hc "$HD/s2" "$HD/good" "$((T0 + 1200))"
expect 0 health_recovery_not_repeated "status=ok" hc "$HD/s2" "$HD/good" "$((T0 + 1500))"
grep -q NOTIFY "$TMP/health_recovery_not_repeated.log" && ko "health_recovery_not_repeated (notified again)"

# A node counts as dead when it fails the GROUP's test URL, even if some other URL still passes it
# (mihomo keeps one result per URL; the fallback group acts on its own).
expect 0 health_alive_follows_the_groups_test_url "nodes=hy2-vps:dead" hc "$HD/s2b" "$HD/hy2-fails-group-url" "$T0"

# A damaged state file is not a crash: the value is ignored and the clock restarts.
mkdir -p "$HD/s2c"; printf 'first_dead_reality_vps=garbage\n' >"$HD/s2c/state.env"
expect 0 health_tolerates_corrupt_state "status=ok" hc "$HD/s2c" "$HD/reality-dead" "$((T0 + 660))"

# Settings for the scheduled task come from health.env in the state dir (environment wins).
mkdir -p "$HD/s2d"; printf 'HEALTH_DEAD_MIN=1   # minutes\n' >"$HD/s2d/health.env"
expect 0 health_env_file_first_sighting "status=ok" hc "$HD/s2d" "$HD/reality-dead" "$T0"
expect 1 health_env_file_sets_thresholds "NOTIFY: reality-vps has been dead for 2 min" hc "$HD/s2d" "$HD/reality-dead" "$((T0 + 120))"

# The optional Kuma push uses the URL up to the token (a pasted ?status=... tail is dropped) and
# never prints the token.
expect 0 health_kuma_push_drops_pasted_query "push: http://127\.0\.0\.1:9/api/push/\*\*\*\?status=up&msg=ok" \
  env HEALTH_DIR="$HD/s2e" HEALTH_API_FIXTURE_DIR="$HD/good" HEALTH_NOW="$T0" HEALTH_NOTIFY=echo \
      HEALTH_KUMA_PUSH_URL="http://127.0.0.1:9/api/push/SECRETTOKEN?status=up&msg=OK&ping=" HEALTH_KUMA_DRY_RUN=1 bash "$H"
grep -q SECRETTOKEN "$TMP/health_kuma_push_drops_pasted_query.log" 2>/dev/null && ko "health_kuma_push_drops_pasted_query (token printed)"

# The group should sit on hy2-vps; anything else for 10 minutes is an alert.
expect 0 health_group_elsewhere_under_10min_is_quiet "status=ok" hc "$HD/s3" "$HD/on-cdn" "$T0"
expect 1 health_group_elsewhere_over_10min_alerts "NOTIFY: PROXY is on cdn-fallback, not hy2-vps, for 11 min" hc "$HD/s3" "$HD/on-cdn" "$((T0 + 660))"

# Rule sets older than 3 days are stale.
expect 1 health_stale_rule_set_alerts "NOTIFY: rule set cn-domain last updated 4 days ago" hc "$HD/s4" "$HD/stale-rules" "$T0"

# No controller → cannot check (exit 2) every time, but the alert waits 10 minutes (Clash Verge
# starting after the first run of the day is not an incident), then fires once.
expect 2 health_unreachable_controller_under_10min_is_quiet "status=unreachable" hc "$HD/s5" "$HD/no-api" "$T0"
grep -q NOTIFY "$TMP/health_unreachable_controller_under_10min_is_quiet.log" && ko "health_unreachable_controller_under_10min_is_quiet (notified early)"
expect 2 health_unreachable_controller_over_10min_alerts "NOTIFY: mihomo controller unreachable" hc "$HD/s5" "$HD/no-api" "$((T0 + 660))"
# A controller that answers but not with mihomo's data (401 body, some other service) is unreachable, not "ok".
expect 2 health_rejected_secret_is_unreachable "status=unreachable" hc "$HD/s5b" "$HD/bad-auth" "$T0"

# The scheduler installer registers a 5-minute task that starts Git Bash in a hidden console
# (notifications need the user's session; a visible console would flash every 5 minutes).
I="$REPO_ROOT/client/install-health-task.sh"
expect 0 health_task_installer_schedules_every_5_min "/SC MINUTE /MO 5" env SCHTASKS_DRY_RUN=1 bash "$I"
expect 0 health_task_installer_hidden_bash_with_plain_quotes 'conhost\.exe --headless "[^"]*bash(\.exe)?" -l "[^"]*/client/health-check\.sh"' \
  env SCHTASKS_DRY_RUN=1 bash "$I"
# schtasks stores the /TR string as given; a \" written here would end up in the task and it would never start.
grep -q '\\"' "$TMP/health_task_installer_hidden_bash_with_plain_quotes.log" && ko "health_task_installer_hidden_bash_with_plain_quotes (escaped quotes in /TR)"
mkdir -p "$TMP/nobin"
expect 0 health_task_installer_dry_run_without_cygpath "/SC MINUTE /MO 5" env PATH="$TMP/nobin" SCHTASKS_DRY_RUN=1 "$BASH" "$I"
expect 0 health_task_installer_remove_deletes_the_task '/Delete /F /TN "mesh-router health"' env SCHTASKS_DRY_RUN=1 bash "$I" --remove

# --- client/probe-node.sh safety -------------------------------------------------------------------
probe_safety() {
  local work="$TMP/probe" P="$REPO_ROOT/client/probe-node.sh"
  mkdir -p "$work"
  # shellcheck source=lib.sh
  source "$SCRIPT_DIR/lib.sh"
  write_throwaway_env "$TMP/probe.env"
  MESH_SECRETS_FILES="$TMP/probe.env" MESH_CLIENT_OUT="$work/config.yaml" MESH_SKIP_RULE_DOWNLOAD=1 \
    bash "$REPO_ROOT/client/render-client-config.sh" >/dev/null 2>&1 || { ko "probe_safety (render failed)"; return; }
  printf 'tun:\n  enable: true\n  stack: gvisor\n' >"$work/tun-on.yaml"
  printf 'tun:\n  enable: false\n' >"$work/tun-off.yaml"

  # With the client's TUN on, the probe's own dials would be captured and tunnelled: refuse.
  expect 2 probe_refuses_when_client_tun_is_on "TUN" \
    env PROBE_CONFIG="$work/config.yaml" PROBE_VERGE_RUNTIME="$work/tun-on.yaml" bash "$P" hy2-vps
  # The run budget grows with the try count (30 s + 12 s per try) instead of a fixed 120 s.
  expect 0 probe_budget_scales_with_count "up to 270 s" \
    env PROBE_CONFIG="$work/config.yaml" PROBE_VERGE_RUNTIME="$work/tun-off.yaml" PROBE_DRY_RUN=1 bash "$P" hy2-vps 20
  # Printed errors never show the servers' addresses (probe output gets pasted into docs).
  # reality-vps's server is an IP (TEST-NET), so mihomo's dial error names it; hy2's error does not.
  expect 1 probe_output_hides_server_addresses "<server>" \
    env PROBE_CONFIG="$work/config.yaml" PROBE_VERGE_RUNTIME="$work/tun-off.yaml" PROBE_DIAL_TIMEOUT=8 PROBE_PORT=17892 bash "$P" reality-vps 1
  if grep -qE 'static\.example\.com|203\.0\.113\.45|cdn\.example\.com' "$TMP/probe_output_hides_server_addresses.log"; then
    ko "probe_output_hides_server_addresses (a server address is printed)"
  else
    ok probe_output_has_no_server_addresses
  fi
}
probe_safety

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]

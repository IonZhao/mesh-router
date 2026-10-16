#!/usr/bin/env bash
# Validate the VPS and client config templates WITHOUT real secrets.
# Renders each template with throwaway values into a temp dir, then asks the real cores:
#   VPS    : every ${VAR} in the template must be substituted by bootstrap.sh, the result must be
#            JSON, and `sing-box check` must accept it.
#   client : rendered through client/render-client-config.sh itself, then `mihomo -t`.
#
#   scripts/validate-configs.sh              # both
#   scripts/validate-configs.sh --vps        # VPS only
#   scripts/validate-configs.sh --client     # client only
#
# Binaries:  sing-box -> $SINGBOX_BIN, else .tools/sing-box-<version pinned in .env>-*/sing-box,
#            else `sing-box` on PATH, else Docker image ghcr.io/sagernet/sing-box:<pinned version>
#            (SINGBOX_USE_DOCKER=1 prefers Docker), else the check is skipped.
#            mihomo   -> $MIHOMO_BIN, else Clash Verge's bundled core, else `mihomo` on PATH.
# Overrides: VPS_TEMPLATE, CLIENT_TEMPLATE (used by scripts/test-configs.sh).
#
# Exit 0 only when every check that could run passed; a skipped check prints WARN.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

VPS_TEMPLATE="${VPS_TEMPLATE:-$REPO_ROOT/vps/sing-box/config.json.template}"
CLIENT_TEMPLATE="${CLIENT_TEMPLATE:-$REPO_ROOT/client/clash-meta.yaml.template}"
BOOTSTRAP="$REPO_ROOT/vps/bootstrap.sh"

DO_VPS=0
DO_CLIENT=0
for a in "$@"; do
  case "$a" in
    --vps) DO_VPS=1 ;;
    --client) DO_CLIENT=1 ;;
    *) echo "usage: $0 [--vps] [--client]" >&2; exit 2 ;;
  esac
done
[[ $DO_VPS -eq 0 && $DO_CLIENT -eq 0 ]] && { DO_VPS=1; DO_CLIENT=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failed=0
ok()   { echo "OK   $*"; }
bad()  { echo "FAIL $*"; failed=1; }
warn() { echo "WARN $*"; }

# `native` (POSIX → D:/… on Windows) comes from lib.sh.

# ---- throwaway values (well-formed, never real) ----------------------------------------------------
write_throwaway_env "$TMP/throwaway.env"

# ---- VPS ----------------------------------------------------------------------------------------
check_vps() {
  local work="$TMP/vps" bvars tvars v missing=() sb=""
  mkdir -p "$work/root/rulesets" "$work/root/acme"

  bvars="$(grep -E "^VARS='" "$BOOTSTRAP" | sed -E "s/^VARS='(.*)'$/\1/")"
  [[ -n "$bvars" ]] || { bad "vps: could not read VARS from $BOOTSTRAP"; return; }
  tvars="$(grep -oE '\$\{[A-Z0-9_]+\}' "$VPS_TEMPLATE" | tr -d '${}' | sort -u)"
  for v in $tvars; do
    [[ " $bvars " == *" \$$v "* ]] || missing+=("$v")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    bad "vps: template variables not substituted by bootstrap.sh VARS: ${missing[*]}"
    return
  fi
  ok "vps: every template variable is in bootstrap.sh VARS"

  ( set -a; source "$TMP/throwaway.env"; set +a; envsubst "$bvars" <"$VPS_TEMPLATE" >"$work/config.json" )
  if grep -qE '\$\{[A-Z0-9_]+\}' "$work/config.json"; then
    bad "vps: unrendered variable left in config: $(grep -oE '\$\{[A-Z0-9_]+\}' "$work/config.json" | sort -u | tr '\n' ' ')"
    return
  fi
  if command -v jq >/dev/null 2>&1; then
    jq empty "$work/config.json" 2>"$work/json.err" || { bad "vps: not valid JSON: $(head -1 "$work/json.err")"; return; }
    ok "vps: rendered config is valid JSON"
  fi

  cp "$REPO_ROOT"/vps/rulesets/*.json "$work/root/rulesets/"
  # MSYS_NO_PATHCONV keeps "/CN=..." intact on Git Bash; the file paths are passed in native form.
  MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$(native "$work/root/acme/cdn-selfsigned.key")" \
    -out "$(native "$work/root/acme/cdn-selfsigned.crt")" \
    -subj "/CN=cdn.local" >/dev/null 2>&1 || { bad "vps: openssl could not create the test cert"; return; }

  local ver have
  ver="$(pinned_singbox_version)"
  [[ -n "$ver" ]] || { bad "vps: SINGBOX_VERSION missing from $(mesh_env_file); cannot pick the sing-box to check with"; return; }

  check_with_binary() {
    sed "s#/etc/sing-box/#$(native "$work/root")/#g" "$work/config.json" >"$work/config.local.json"
    if "$1" check -c "$(native "$work/config.local.json")" >"$work/check.log" 2>&1; then
      ok "vps: sing-box check passed ($("$1" version 2>/dev/null | head -1))"
    else
      bad "vps: sing-box check: $(tail -3 "$work/check.log" | tr '\n' ' ')"
    fi
  }
  check_with_docker() {
    # Mount sources in native form: Docker Desktop cannot see Git Bash's /tmp.
    if MSYS_NO_PATHCONV=1 docker run --rm \
         -v "$(native "$work/config.json"):/c.json:ro" \
         -v "$(native "$work/root/rulesets"):/etc/sing-box/rulesets:ro" \
         -v "$(native "$work/root/acme"):/etc/sing-box/acme:ro" \
         "ghcr.io/sagernet/sing-box:${ver}" check -c /c.json >"$work/check.log" 2>&1; then
      ok "vps: sing-box check passed (docker ${ver})"
    else
      bad "vps: sing-box check: $(tail -3 "$work/check.log" | tr '\n' ' ')"
    fi
  }

  sb="$(find_singbox)"
  if [[ -n "${SINGBOX_USE_DOCKER:-}" ]]; then
    if docker_up; then check_with_docker; else bad "vps: SINGBOX_USE_DOCKER=1 is set but Docker is not running"; fi
  elif [[ -n "$sb" ]]; then
    have="$(singbox_version_of "$sb")"
    [[ "$have" == "${ver#v}" ]] || warn "vps: sing-box $have found but .env pins $ver, which is what the VPS runs; the result may differ"
    check_with_binary "$sb"
  elif docker_up; then
    check_with_docker
  else
    warn "vps: no sing-box $ver binary (set SINGBOX_BIN or unpack .tools/sing-box-${ver#v}-$(host_platform)/, README: Validating locally) and Docker is not running; sing-box check skipped"
  fi
}

# ---- client -------------------------------------------------------------------------------------
check_client() {
  local work="$TMP/client" bin
  mkdir -p "$work"
  if ! MESH_SECRETS_FILES="$TMP/throwaway.env" MESH_CLIENT_TPL="$CLIENT_TEMPLATE" \
       MESH_CLIENT_OUT="$work/config.yaml" MESH_SKIP_RULE_DOWNLOAD=1 \
       bash "$REPO_ROOT/client/render-client-config.sh" >"$work/render.log" 2>&1; then
    bad "client: render failed: $(tail -2 "$work/render.log" | tr '\n' ' ')"
    return
  fi
  # Only real placeholders count; the template's comments mention "${...}" literally.
  if grep -vE '^\s*#' "$work/config.yaml" | grep -qE '\$\{[A-Z0-9_]+\}'; then
    bad "client: unrendered variable left in config: $(grep -vE '^\s*#' "$work/config.yaml" | grep -oE '\$\{[A-Z0-9_]+\}' | sort -u | tr '\n' ' ')"
    return
  fi
  ok "client: rendered through render-client-config.sh"

  bin="$(find_mihomo)"
  if [[ -z "$bin" ]]; then
    warn "client: no mihomo binary found (set MIHOMO_BIN); mihomo -t skipped"
    return
  fi
  seed_geo_files "$bin" "$work"
  [[ -d "$REPO_ROOT/client/rules" ]] && cp -r "$REPO_ROOT/client/rules" "$work/"
  if "$bin" -t -d "$(native "$work")" -f "$(native "$work/config.yaml")" >"$work/t.log" 2>&1; then
    ok "client: $(grep -o 'configuration file .* test is successful' "$work/t.log" | sed 's#configuration file .*/#configuration file #')"
  else
    bad "client: mihomo -t: $(grep -iE 'error|fatal|fail' "$work/t.log" | tail -2 | tr '\n' ' ')"
  fi
}

[[ $DO_VPS -eq 1 ]] && check_vps
[[ $DO_CLIENT -eq 1 ]] && check_client
exit $failed

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
# Binaries:  sing-box -> $SINGBOX_BIN, else `sing-box` on PATH, else Docker image
#            ghcr.io/sagernet/sing-box:$SINGBOX_VERSION (from .env), else the check is skipped.
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

# Native-path form of a POSIX path (Windows binaries need D:/..., everything else is unchanged).
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

# ---- throwaway values (well-formed, never real) ---------------------------------------------------
uuid4() {
  local h
  h="$(openssl rand -hex 16)"
  printf '%s-%s-4%s-a%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
}
b64url32() { openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n'; }

cat >"$TMP/throwaway.env" <<EOF
VPS_HOST=203.0.113.45
STATIC_DOMAIN=static.example.com
CDN_DOMAIN=cdn.example.com
ACME_EMAIL=ops@example.com
REALITY_HANDSHAKE=dl.google.com
MAC_TAILSCALE_IP=100.64.0.1
VLESS_UUID=$(uuid4)
MAC_VLESS_UUID=$(uuid4)
REALITY_PRIVATE_KEY=$(b64url32)
REALITY_PUBLIC_KEY=$(b64url32)
REALITY_SHORT_ID=0123456789abcdef
HY2_PASSWORD=$(openssl rand -hex 12)
HY2_OBFS_PASSWORD=$(openssl rand -hex 12)
CLASH_API_SECRET=$(openssl rand -hex 12)
CDN_WS_PATH=$(openssl rand -hex 12)
SINGBOX_LOG_LEVEL=info
EOF

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

  if [[ -n "${SINGBOX_BIN:-}" ]]; then
    sb="$SINGBOX_BIN"
  elif command -v sing-box >/dev/null 2>&1; then
    sb="$(command -v sing-box)"
  fi

  if [[ -n "$sb" ]]; then
    sed "s#/etc/sing-box/#$(native "$work/root")/#g" "$work/config.json" >"$work/config.local.json"
    if "$sb" check -c "$(native "$work/config.local.json")" >"$work/check.log" 2>&1; then
      ok "vps: sing-box check passed ($("$sb" version 2>/dev/null | head -1))"
    else
      bad "vps: sing-box check: $(tail -3 "$work/check.log" | tr '\n' ' ')"
    fi
  elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    local ver
    ver="$(grep -E '^SINGBOX_VERSION=' "$REPO_ROOT/.env" | cut -d= -f2)"
    if MSYS_NO_PATHCONV=1 docker run --rm \
         -v "$work/config.json:/c.json:ro" \
         -v "$work/root/rulesets:/etc/sing-box/rulesets:ro" \
         -v "$work/root/acme:/etc/sing-box/acme:ro" \
         "ghcr.io/sagernet/sing-box:${ver:-v1.11.14}" check -c /c.json >"$work/check.log" 2>&1; then
      ok "vps: sing-box check passed (docker ${ver})"
    else
      bad "vps: sing-box check: $(tail -3 "$work/check.log" | tr '\n' ' ')"
    fi
  else
    warn "vps: no sing-box binary and Docker is not available; sing-box check skipped (bootstrap.sh runs it on the VPS)"
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

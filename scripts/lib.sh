# Shared helpers for the local tooling scripts (sourced, not executed).

# Print the path of a mihomo binary, or nothing when none is found.
# Order: $MIHOMO_BIN, Clash Verge's bundled core on Windows, `mihomo` on PATH.
find_mihomo() {
  if [[ -n "${MIHOMO_BIN:-}" ]]; then
    printf '%s\n' "$MIHOMO_BIN"
    return
  fi
  local verge="D:/Program/Software/Clash Verge/verge-mihomo.exe"
  if [[ -x "$verge" ]]; then
    printf '%s\n' "$verge"
    return
  fi
  command -v mihomo 2>/dev/null || true
}

# Write well-formed throwaway values for every secret the templates use (never real ones).
write_throwaway_env() {
  local out="$1" h1 h2
  h1="$(openssl rand -hex 16)"
  h2="$(openssl rand -hex 16)"
  cat >"$out" <<EOF
VPS_HOST=203.0.113.45
STATIC_DOMAIN=static.example.com
CDN_DOMAIN=cdn.example.com
ACME_EMAIL=ops@example.com
REALITY_HANDSHAKE=dl.google.com
MAC_TAILSCALE_IP=100.64.0.1
VLESS_UUID=${h1:0:8}-${h1:8:4}-4${h1:13:3}-a${h1:17:3}-${h1:20:12}
MAC_VLESS_UUID=${h2:0:8}-${h2:8:4}-4${h2:13:3}-a${h2:17:3}-${h2:20:12}
REALITY_PRIVATE_KEY=$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n')
REALITY_PUBLIC_KEY=$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n')
REALITY_SHORT_ID=0123456789abcdef
HY2_PASSWORD=$(openssl rand -hex 12)
HY2_OBFS_PASSWORD=$(openssl rand -hex 12)
CLASH_API_SECRET=$(openssl rand -hex 12)
CDN_WS_PATH=$(openssl rand -hex 12)
SINGBOX_LOG_LEVEL=info
EOF
}

# Copy mihomo's geo databases next to a config so a test run never downloads them.
# Source: $MIHOMO_GEO_DIR, else the `resources/` folder beside the binary (Clash Verge layout).
seed_geo_files() {
  local bin="$1" dest="$2" src="${MIHOMO_GEO_DIR:-}"
  [[ -z "$src" ]] && src="$(dirname "$bin")/resources"
  [[ -d "$src" ]] || return 0
  cp "$src"/*.dat "$src"/*.mmdb "$dest"/ 2>/dev/null || true
}

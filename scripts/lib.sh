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

# Copy mihomo's geo databases next to a config so a test run never downloads them.
# Source: $MIHOMO_GEO_DIR, else the `resources/` folder beside the binary (Clash Verge layout).
seed_geo_files() {
  local bin="$1" dest="$2" src="${MIHOMO_GEO_DIR:-}"
  [[ -z "$src" ]] && src="$(dirname "$bin")/resources"
  [[ -d "$src" ]] || return 0
  cp "$src"/*.dat "$src"/*.mmdb "$dest"/ 2>/dev/null || true
}

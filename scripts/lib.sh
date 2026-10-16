# Shared helpers for the local tooling scripts (sourced, not executed). Bash 3.2 compatible.

# Repo root (this file lives in scripts/).
mesh_repo_root() { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }

# The repo-root .env (MESH_ENV_FILE overrides it for tests).
mesh_env_file() { printf '%s\n' "${MESH_ENV_FILE:-$(mesh_repo_root)/.env}"; }

# POSIX form of a path that may be a Windows path (Git Bash); unchanged elsewhere.
to_posix() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1" 2>/dev/null || printf '%s\n' "$1"
  else printf '%s\n' "$1"; fi
}

# Native form of a POSIX path for Windows programs and Docker Desktop (D:/…); unchanged elsewhere.
native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1" 2>/dev/null || printf '%s\n' "$1"
  else printf '%s\n' "$1"; fi
}

# "<os>-<arch>" the way sing-box names its release assets: linux-amd64, windows-amd64, darwin-arm64…
host_platform() {
  local os arch
  case "$(uname -s)" in
    Linux*) os=linux ;;
    Darwin*) os=darwin ;;
    MINGW*|MSYS*|CYGWIN*) os=windows ;;
    *) os="$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) arch="$(uname -m)" ;;
  esac
  printf '%s-%s\n' "$os" "$arch"
}

# Print the path of a mihomo binary, or nothing when none is found.
# Order: $MIHOMO_BIN, $MESH_CLASH_VERGE_DIR, the folder of a running clash-verge.exe (Windows),
# Clash Verge's default install folders, `mihomo` on PATH.
find_mihomo() {
  local d candidates=() c
  if [[ -n "${MIHOMO_BIN:-}" ]]; then printf '%s\n' "$MIHOMO_BIN"; return; fi
  [[ -n "${MESH_CLASH_VERGE_DIR:-}" ]] && candidates+=("$MESH_CLASH_VERGE_DIR")
  if [[ -z "${MESH_MIHOMO_NO_PROCESS:-}" ]] && command -v powershell >/dev/null 2>&1; then
    d="$(powershell -NoProfile -Command '(Get-Process clash-verge -ErrorAction SilentlyContinue | Select-Object -First 1).Path' 2>/dev/null | tr -d '\r')"
    [[ -n "$d" ]] && candidates+=("$(dirname "$(to_posix "$d")")")
  fi
  [[ -n "${PROGRAMFILES:-}" ]] && candidates+=("$(to_posix "$PROGRAMFILES")/Clash Verge")
  [[ -n "${LOCALAPPDATA:-}" ]] && candidates+=("$(to_posix "$LOCALAPPDATA")/Programs/Clash Verge")
  for c in "${candidates[@]}"; do
    [[ -x "$c/verge-mihomo.exe" ]] && { printf '%s\n' "$c/verge-mihomo.exe"; return; }
    [[ -x "$c/verge-mihomo" ]] && { printf '%s\n' "$c/verge-mihomo"; return; }
  done
  command -v mihomo 2>/dev/null || true
}

# The sing-box version the VPS runs (SINGBOX_VERSION in .env), e.g. v1.11.14; empty when unknown.
pinned_singbox_version() {
  local f
  f="$(mesh_env_file)"
  [[ -f "$f" ]] || return 0
  grep -E '^SINGBOX_VERSION=' "$f" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '\r'
}

# Print the path of a sing-box binary for local checks, or nothing when none is found.
# Order: $SINGBOX_BIN, the pinned version for THIS platform unpacked under .tools/
# (README: Validating locally; MESH_TOOLS_DIR overrides the folder), `sing-box` on PATH.
find_singbox() {
  local tools ver dir f
  if [[ -n "${SINGBOX_BIN:-}" ]]; then printf '%s\n' "$SINGBOX_BIN"; return; fi
  tools="${MESH_TOOLS_DIR:-$(mesh_repo_root)/.tools}"
  ver="$(pinned_singbox_version)"
  if [[ -n "$ver" ]]; then
    dir="$tools/sing-box-${ver#v}-$(host_platform)"
    for f in "$dir/sing-box.exe" "$dir/sing-box"; do   # .exe first: MSYS also answers to the bare name
      [[ -x "$f" ]] && { printf '%s\n' "$f"; return; }
    done
  fi
  command -v sing-box 2>/dev/null || true
}

# "1.11.14" for the binary at $1, or empty.
singbox_version_of() { "$1" version 2>/dev/null | head -1 | awk '{print $3}'; }

# True when a Docker daemon answers.
docker_up() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

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

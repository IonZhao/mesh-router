#!/usr/bin/env bash
# Generate all random secrets (UUIDs, Reality keypair, short id, passwords) using sing-box,
# and write them into secrets/vps.env and secrets/mac.env (created from *.example if missing).
# Human-provided fields (PROXY_DOMAIN, ACME_EMAIL, TS_AUTHKEY, VPS_HOST, MAC_TAILSCALE_IP)
# are left for you to fill in.
#
#   scripts/gen-secrets.sh
#
# Requires Docker (runs sing-box in a throwaway container; no local install needed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VPS_ENV="$REPO_ROOT/secrets/vps.env"
MAC_ENV="$REPO_ROOT/secrets/mac.env"
SB_IMAGE="ghcr.io/sagernet/sing-box:${SINGBOX_VERSION:-v1.11.14}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || die "docker not found."

sb() { docker run --rm "$SB_IMAGE" "$@"; }

set_kv() {
  local key="$1" val="$2" file="$3" tmp line
  tmp="$(mktemp)"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        "${key}="*) printf '%s=%s\n' "$key" "$val" ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
    rm -f "$tmp"
  fi
}

# Seed files from examples if absent.
[[ -f "$VPS_ENV" ]] || cp "$REPO_ROOT/secrets/vps.env.example" "$VPS_ENV"
[[ -f "$MAC_ENV" ]] || cp "$REPO_ROOT/secrets/mac.env.example" "$MAC_ENV"

echo "Generating secrets with $SB_IMAGE ..."
VLESS_UUID="$(sb generate uuid)"
MAC_VLESS_UUID="$(sb generate uuid)"
REALITY_SHORT_ID="$(sb generate rand 8 --hex)"
HY2_PASSWORD="$(sb generate rand 24 --hex)"
CLASH_API_SECRET="$(sb generate rand 24 --hex)"

KP="$(sb generate reality-keypair)"
REALITY_PRIVATE_KEY="$(printf '%s\n' "$KP" | awk -F': *' '/PrivateKey/{print $2}')"
REALITY_PUBLIC_KEY="$(printf '%s\n' "$KP" | awk -F': *' '/PublicKey/{print $2}')"
[[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || die "Failed to parse Reality keypair."

# VPS side.
set_kv VLESS_UUID          "$VLESS_UUID"          "$VPS_ENV"
set_kv REALITY_PRIVATE_KEY "$REALITY_PRIVATE_KEY" "$VPS_ENV"
set_kv REALITY_SHORT_ID    "$REALITY_SHORT_ID"    "$VPS_ENV"
set_kv HY2_PASSWORD        "$HY2_PASSWORD"        "$VPS_ENV"
set_kv MAC_VLESS_UUID      "$MAC_VLESS_UUID"      "$VPS_ENV"
set_kv CLASH_API_SECRET    "$CLASH_API_SECRET"    "$VPS_ENV"

# Mac side (shared UUID + the public key for client reference).
set_kv MAC_VLESS_UUID      "$MAC_VLESS_UUID"      "$MAC_ENV"
set_kv REALITY_PUBLIC_KEY  "$REALITY_PUBLIC_KEY"  "$MAC_ENV"
# Convenience: stash the public key + short id in vps.env too so render-client-config.sh finds them.
set_kv REALITY_PUBLIC_KEY  "$REALITY_PUBLIC_KEY"  "$VPS_ENV"

cat <<EOF

Secrets written to:
  $VPS_ENV
  $MAC_ENV

Reality PUBLIC key (goes into the client config; safe to share):
  $REALITY_PUBLIC_KEY

STILL TO FILL IN BY HAND:
  secrets/vps.env : PROXY_DOMAIN, ACME_EMAIL, REALITY_HANDSHAKE, TS_AUTHKEY, VPS_HOST, MAC_TAILSCALE_IP
  secrets/mac.env : TS_AUTHKEY   (a separate Tailscale auth key for the Mac node)

Then encrypt for git (optional but recommended):
  sops -e secrets/vps.env > secrets/vps.env.enc
  sops -e secrets/mac.env > secrets/mac.env.enc
EOF

#!/usr/bin/env bash
# VPS bootstrap — fresh Debian/Ubuntu machine -> running proxy stack.
# Idempotent: safe to re-run after editing config or rotating secrets.
#
#   git clone <repo> && cd mesh-router/vps && ./bootstrap.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS="$REPO_ROOT/secrets/vps.env"
SECRETS_ENC="$REPO_ROOT/secrets/vps.env.enc"
TEMPLATE="$SCRIPT_DIR/sing-box/config.json.template"
RENDERED="$SCRIPT_DIR/sing-box/config.json"

log() { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[bootstrap] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Docker present?
command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker Engine + compose plugin first (see README)."
docker compose version >/dev/null 2>&1 || die "docker compose plugin not found."

# 2. Resolve secrets: plaintext wins; else decrypt the sops file; else guide the user.
if [[ ! -f "$SECRETS" ]]; then
  if [[ -f "$SECRETS_ENC" ]]; then
    command -v sops >/dev/null 2>&1 || die "secrets/vps.env.enc exists but 'sops' is not installed."
    log "Decrypting secrets/vps.env.enc with sops..."
    sops -d "$SECRETS_ENC" > "$SECRETS"
  else
    die "No secrets found. Run 'scripts/gen-secrets.sh' first, or copy secrets/vps.env.example -> secrets/vps.env and fill it in."
  fi
fi

# 3. Load + validate required variables.
set -a; # shellcheck disable=SC1090
source "$SECRETS"; set +a
REQUIRED=(PROXY_DOMAIN ACME_EMAIL REALITY_HANDSHAKE MAC_TAILSCALE_IP TS_AUTHKEY \
          VLESS_UUID REALITY_PRIVATE_KEY REALITY_SHORT_ID HY2_PASSWORD MAC_VLESS_UUID CLASH_API_SECRET CDN_WS_PATH)
for v in "${REQUIRED[@]}"; do
  [[ -n "${!v:-}" ]] || die "Required secret '$v' is empty in secrets/vps.env"
done
case "$MAC_TAILSCALE_IP" in 100.x.*) die "MAC_TAILSCALE_IP is still a placeholder. Set up the Mac mini first and copy its 'tailscale ip -4' value." ;; esac

# 4. Render config.json from the template (only our known vars are substituted).
command -v envsubst >/dev/null 2>&1 || die "envsubst not found. Install: apt-get install -y gettext-base"
VARS='$PROXY_DOMAIN $ACME_EMAIL $REALITY_HANDSHAKE $MAC_TAILSCALE_IP $VLESS_UUID $REALITY_PRIVATE_KEY $REALITY_SHORT_ID $HY2_PASSWORD $MAC_VLESS_UUID $CLASH_API_SECRET $CDN_WS_PATH'
log "Rendering sing-box/config.json from template..."
envsubst "$VARS" < "$TEMPLATE" > "$RENDERED"

# 5. Data directories for persisted volumes.
mkdir -p "$SCRIPT_DIR"/data/{sing-box,tailscale,netdata/config,netdata/lib,netdata/cache,uptime-kuma,vnstat} "$SCRIPT_DIR/acme"

# 5b. Self-signed cert for the optional Cloudflare CDN fallback inbound (port 2053).
#     Cloudflare "Full" mode encrypts CF<->origin but does NOT validate the cert, so self-signed
#     is fine. The inbound just sits dark until you point Cloudflare at it (see docs/cloudflare-fallback.md).
if [[ ! -f "$SCRIPT_DIR/acme/cdn-selfsigned.crt" ]]; then
  command -v openssl >/dev/null 2>&1 || die "openssl not found (apt-get install -y openssl) — needed for the CDN fallback cert."
  log "Generating self-signed cert for the CDN fallback inbound..."
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$SCRIPT_DIR/acme/cdn-selfsigned.key" \
    -out "$SCRIPT_DIR/acme/cdn-selfsigned.crt" \
    -subj "/CN=cdn.local" >/dev/null 2>&1 || die "openssl cert generation failed."
fi

# 6. Validate the rendered config before starting.
log "Validating sing-box config..."
docker run --rm -v "$SCRIPT_DIR/sing-box/config.json:/c.json:ro" -v "$SCRIPT_DIR/rulesets:/etc/sing-box/rulesets:ro" \
  -v "$SCRIPT_DIR/acme:/etc/sing-box/acme:ro" \
  "ghcr.io/sagernet/sing-box:${SINGBOX_VERSION:-v1.11.14}" check -c /c.json \
  || die "sing-box config validation failed (see output above)."

# 7. Up.
#    --env-file points at the repo-root .env (image tags etc.); compose's default .env
#    lookup is the cwd (vps/), which has none — without this the *_VERSION vars are blank.
log "Starting stack..."
( cd "$SCRIPT_DIR" && docker compose --env-file "$REPO_ROOT/.env" up -d )

# 7b. Apply config/secret changes. `up -d` won't recreate sing-box when only its
#     bind-mounted config.json changed, and sing-box doesn't hot-reload — so restart it
#     explicitly. Without this, re-running after editing config silently keeps the old one.
log "Restarting sing-box to load the current config..."
( cd "$SCRIPT_DIR" && docker compose --env-file "$REPO_ROOT/.env" restart sing-box )

log "Done. Next:"
echo "  - Check Tailscale joined:   docker exec tailscale tailscale status"
echo "  - Apply firewall:           sudo ../scripts/firewall.sh"
echo "  - Dashboard (via Tailscale): http://<vps-tailscale-ip>:9090/ui  (secret = CLASH_API_SECRET)"
echo "  - Netdata (via Tailscale):   http://<vps-tailscale-ip>:19999"
echo "  - Uptime Kuma (via Tailscale): http://<vps-tailscale-ip>:3001"

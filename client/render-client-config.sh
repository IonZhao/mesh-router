#!/usr/bin/env bash
# Render the Clash Meta client config from the template + secrets.
# Run on any machine that has the secrets (then copy the output to your China-side client).
#
#   ./render-client-config.sh            # uses ../secrets/vps.env + ../secrets/mac.env
#
# Needs from secrets: VPS_HOST, VLESS_UUID, REALITY_HANDSHAKE, REALITY_PUBLIC_KEY,
#                     REALITY_SHORT_ID, PROXY_DOMAIN, HY2_PASSWORD
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TPL="$SCRIPT_DIR/clash-meta.yaml.template"
OUT="$SCRIPT_DIR/clash-meta.yaml"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Load secrets (vps.env has most; mac.env carries REALITY_PUBLIC_KEY for reference).
for f in "$REPO_ROOT/secrets/vps.env" "$REPO_ROOT/secrets/mac.env"; do
  [[ -f "$f" ]] && { set -a; source "$f"; set +a; }
done

: "${VPS_HOST:?Set VPS_HOST (VPS public IP) in secrets/vps.env}"
: "${VLESS_UUID:?missing}"; : "${REALITY_HANDSHAKE:?missing}"; : "${REALITY_PUBLIC_KEY:?missing in secrets (printed by gen-secrets.sh)}"
: "${REALITY_SHORT_ID:?missing}"; : "${PROXY_DOMAIN:?missing}"; : "${HY2_PASSWORD:?missing}"
# CDN fallback is optional — default to harmless values so the rendered config stays valid (and the
# proxy simply tests dead in the url-test group) when Cloudflare hasn't been set up yet.
CDN_DOMAIN="${CDN_DOMAIN:-cdn.invalid}"
CDN_WS_PATH="${CDN_WS_PATH:-cdnfallback}"

sed -e "s|\${VPS_HOST}|$VPS_HOST|g" \
    -e "s|\${VLESS_UUID}|$VLESS_UUID|g" \
    -e "s|\${REALITY_HANDSHAKE}|$REALITY_HANDSHAKE|g" \
    -e "s|\${REALITY_PUBLIC_KEY}|$REALITY_PUBLIC_KEY|g" \
    -e "s|\${REALITY_SHORT_ID}|$REALITY_SHORT_ID|g" \
    -e "s|\${PROXY_DOMAIN}|$PROXY_DOMAIN|g" \
    -e "s|\${HY2_PASSWORD}|$HY2_PASSWORD|g" \
    -e "s|\${CDN_DOMAIN}|$CDN_DOMAIN|g" \
    -e "s|\${CDN_WS_PATH}|$CDN_WS_PATH|g" \
    "$TPL" > "$OUT"

echo "Wrote $OUT"
echo "Import it into Clash Meta / mihomo (Clash Verge, FlClash, mihomo Party, etc.) on your China-side machine."

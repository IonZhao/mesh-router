#!/usr/bin/env bash
# Generate node share-links (URIs) + a base64 subscription from secrets, for NON-Clash clients
# (Shadowrocket, v2rayN, NekoBox, sing-box apps, etc.). The Clash.Meta config is produced
# separately by render-client-config.sh — this is the universal-import equivalent.
#
# Outputs (gitignored — they contain secrets, treat like a password):
#   client/share-links.txt    one URI per line (paste individually into any client)
#   client/subscription.txt   base64 of those URIs — this is the "one subscription" format.
#                             Import it as a LOCAL file, or host it at a PRIVATE/secret URL
#                             (e.g. served over Tailscale). NEVER expose it publicly — anyone
#                             with the file/URL gets full access to your proxy.
#
# Routing note: share links carry ONLY the nodes — NOT the CN-direct / fake-ip / failover logic
# that clash-meta.yaml has. In a non-Clash client you configure routing rules yourself (or just
# use a Clash.Meta client with clash-meta.yaml and get the rules for free).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LINKS="$SCRIPT_DIR/share-links.txt"
SUB="$SCRIPT_DIR/subscription.txt"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for f in "$REPO_ROOT/secrets/vps.env" "$REPO_ROOT/secrets/mac.env"; do
  [[ -f "$f" ]] && { set -a; source "$f"; set +a; }
done

: "${VPS_HOST:?Set VPS_HOST in secrets/vps.env}"
: "${VLESS_UUID:?missing}"; : "${REALITY_HANDSHAKE:?missing}"
: "${REALITY_PUBLIC_KEY:?missing in secrets (gen-secrets.sh prints it)}"; : "${REALITY_SHORT_ID:?missing}"
: "${STATIC_DOMAIN:?missing}"; : "${HY2_PASSWORD:?missing}"
# CDN fallback is optional; default to harmless placeholders if not set up yet.
CDN_DOMAIN="${CDN_DOMAIN:-cdn.invalid}"
CDN_WS_PATH="${CDN_WS_PATH:-cdnfallback}"

# Note: gen-secrets.sh produces URL-safe values (hex / uuid / base64url), so only the WS path's
# leading slash needs encoding (%2F). If you hand-set a password with special chars, URL-encode it.
REALITY="vless://${VLESS_UUID}@${VPS_HOST}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_HANDSHAKE}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#reality-vps"
HY2="hysteria2://${HY2_PASSWORD}@${STATIC_DOMAIN}:8443/?sni=${STATIC_DOMAIN}&alpn=h3#hy2-vps"
CDN="vless://${VLESS_UUID}@${CDN_DOMAIN}:2053?encryption=none&security=tls&sni=${CDN_DOMAIN}&fp=chrome&type=ws&host=${CDN_DOMAIN}&path=%2F${CDN_WS_PATH}#cdn-fallback"

printf '%s\n%s\n%s\n' "$REALITY" "$HY2" "$CDN" > "$LINKS"
# Standard subscription = base64 of the newline-joined URIs.
base64 -w0 "$LINKS" 2>/dev/null > "$SUB" || base64 "$LINKS" | tr -d '\n' > "$SUB"

# Print ONLY paths + instructions — never the link contents (they hold secrets).
echo "Wrote:"
echo "  $LINKS    (3 node URIs, one per line)"
echo "  $SUB      (base64 subscription — the 'one link/file' format)"
echo
echo "Shadowrocket / v2rayN / NekoBox:"
echo "  - paste a single URI from share-links.txt  (+  ->  add node), or"
echo "  - import subscription.txt as a LOCAL subscription file."
echo "Both files contain your UUID / password / keys — keep them private (never commit, never expose)."
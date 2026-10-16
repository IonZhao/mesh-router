#!/usr/bin/env bash
# Render the Clash Meta client config from the template + secrets.
# Run on any machine that has the secrets (then copy the output to your China-side client).
#
#   ./render-client-config.sh            # uses ../secrets/vps.env + ../secrets/mac.env
#
# Needs from secrets: VPS_HOST, VLESS_UUID, REALITY_HANDSHAKE, REALITY_PUBLIC_KEY,
#                     REALITY_SHORT_ID, STATIC_DOMAIN, HY2_PASSWORD
#
# Overrides used by scripts/validate-configs.sh (render with throwaway values, never real secrets):
#   MESH_SECRETS_FILES  env files to load instead of the two secrets files, one path per line
#   MESH_CLIENT_TPL     template to render            MESH_CLIENT_OUT  where to write the result
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TPL="${MESH_CLIENT_TPL:-$SCRIPT_DIR/clash-meta.yaml.template}"
OUT="${MESH_CLIENT_OUT:-$SCRIPT_DIR/clash-meta.yaml}"
SECRETS_FILES=("$REPO_ROOT/secrets/vps.env" "$REPO_ROOT/secrets/mac.env")
if [[ -n "${MESH_SECRETS_FILES:-}" ]]; then
  SECRETS_FILES=()
  while IFS= read -r f; do [[ -n "$f" ]] && SECRETS_FILES+=("$f"); done <<<"$MESH_SECRETS_FILES"
fi

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Load secrets (vps.env has most; mac.env carries REALITY_PUBLIC_KEY for reference).
for f in "${SECRETS_FILES[@]}"; do
  [[ -f "$f" ]] && { set -a; source "$f"; set +a; }
done

: "${VPS_HOST:?Set VPS_HOST (VPS public IP) in secrets/vps.env}"
: "${VLESS_UUID:?missing}"; : "${REALITY_HANDSHAKE:?missing}"; : "${REALITY_PUBLIC_KEY:?missing in secrets (printed by gen-secrets.sh)}"
: "${REALITY_SHORT_ID:?missing}"; : "${STATIC_DOMAIN:?missing}"; : "${HY2_PASSWORD:?missing}"
# CDN fallback is optional — default to harmless values so the rendered config stays valid (and the
# proxy simply tests dead in the fallback group) when Cloudflare hasn't been set up yet.
CDN_DOMAIN="${CDN_DOMAIN:-cdn.invalid}"
CDN_WS_PATH="${CDN_WS_PATH:-cdnfallback}"

sed -e "s|\${VPS_HOST}|$VPS_HOST|g" \
    -e "s|\${VLESS_UUID}|$VLESS_UUID|g" \
    -e "s|\${REALITY_HANDSHAKE}|$REALITY_HANDSHAKE|g" \
    -e "s|\${REALITY_PUBLIC_KEY}|$REALITY_PUBLIC_KEY|g" \
    -e "s|\${REALITY_SHORT_ID}|$REALITY_SHORT_ID|g" \
    -e "s|\${STATIC_DOMAIN}|$STATIC_DOMAIN|g" \
    -e "s|\${HY2_PASSWORD}|$HY2_PASSWORD|g" \
    -e "s|\${CDN_DOMAIN}|$CDN_DOMAIN|g" \
    -e "s|\${CDN_WS_PATH}|$CDN_WS_PATH|g" \
    "$TPL" > "$OUT"

echo "Wrote $OUT"

# Pre-download the remote rule sets (url/path pairs read from the rendered rule-providers section)
# into $RULES_DIR, so the client's first start does not depend on reaching the mirrors: without a
# cached file mihomo holds all traffic for a few seconds while it retries the download.
# A failed download only warns — the client fetches the file itself later.
RULES_DIR="${MESH_RULES_DIR:-$SCRIPT_DIR}"
if [[ -z "${MESH_SKIP_RULE_DOWNLOAD:-}" ]]; then
  awk '
    /^[A-Za-z]/ { section = $1; next }
    section != "rule-providers:" { next }
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { name = $1; sub(":", "", name); next }
    /^[[:space:]]+url:/  { url[name] = $2 }
    /^[[:space:]]+path:/ { path[name] = $2 }
    END { for (n in url) if (n in path) print url[n], path[n] }
  ' "$OUT" | while read -r url path; do
    rel="${path#./}"
    dest="$RULES_DIR/$rel"
    if [[ -s "$dest" ]]; then echo "  present:    $rel"; continue; fi
    mkdir -p "$(dirname "$dest")"
    if curl -fsSL --max-time 30 -o "$dest.part" "$url" 2>/dev/null; then
      mv "$dest.part" "$dest"
      echo "  downloaded: $rel"
    else
      rm -f "$dest.part"
      echo "  WARN: could not download $url (the client will fetch it itself)"
    fi
  done
fi

echo "Import it into Clash Meta / mihomo (Clash Verge, FlClash, mihomo Party, etc.) on your China-side machine,"
echo "and copy $RULES_DIR/rules/ into that client's config directory (Clash Verge on Windows:"
echo "%APPDATA%\\io.github.clash-verge-rev.clash-verge-rev\\rules\\). Add always-direct domains to the"
echo "direct-extra payload in clash-meta.yaml.template and re-render."

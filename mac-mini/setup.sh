#!/usr/bin/env bash
# Mac mini setup — fresh macOS -> running residential exit node.
# NOT docker-based (Docker-on-macOS is a Linux VM with poor networking); uses brew + launchd.
# Idempotent: safe to re-run.
#
#   git clone <repo> && cd mesh-router/mac-mini && ./setup.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS="$REPO_ROOT/secrets/mac.env"
SECRETS_ENC="$REPO_ROOT/secrets/mac.env.enc"
CONFIG_TPL="$SCRIPT_DIR/sing-box/config.json.template"
CONFIG_OUT="$SCRIPT_DIR/sing-box/config.json"
PLIST_TPL="$SCRIPT_DIR/launchd/com.meshrouter.singbox.plist.template"
PLIST_OUT="$SCRIPT_DIR/launchd/com.meshrouter.singbox.plist"
PLIST_DEST="/Library/LaunchDaemons/com.meshrouter.singbox.plist"
LOG_DIR="$HOME/Library/Logs/mesh-router"

log() { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[setup] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Homebrew + packages.
command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install from https://brew.sh first."
BREW_PREFIX="$(brew --prefix)"
command -v sing-box >/dev/null 2>&1 || { log "Installing sing-box..."; brew install sing-box; }
command -v tailscale >/dev/null 2>&1 || { log "Installing tailscale..."; brew install tailscale; }
SINGBOX_BIN="$(command -v sing-box)"

# 2. Resolve secrets.
if [[ ! -f "$SECRETS" ]]; then
  if [[ -f "$SECRETS_ENC" ]]; then
    command -v sops >/dev/null 2>&1 || die "secrets/mac.env.enc exists but 'sops' is not installed (brew install sops)."
    log "Decrypting secrets/mac.env.enc..."
    sops -d "$SECRETS_ENC" > "$SECRETS"
  else
    die "No secrets. Run scripts/gen-secrets.sh, or copy secrets/mac.env.example -> secrets/mac.env and fill it in."
  fi
fi
set -a; source "$SECRETS"; set +a
[[ -n "${TS_AUTHKEY:-}" ]]     || die "TS_AUTHKEY empty in secrets/mac.env"
[[ -n "${MAC_VLESS_UUID:-}" ]] || die "MAC_VLESS_UUID empty in secrets/mac.env"
MAC_VLESS_PORT="${MAC_VLESS_PORT:-18443}"

# 3. Tailscale up (idempotent).
log "Starting tailscaled..."
sudo brew services start tailscale >/dev/null 2>&1 || true
sleep 2
if ! tailscale status >/dev/null 2>&1; then
  log "Joining tailnet..."
  sudo tailscale up --authkey="$TS_AUTHKEY" --hostname=mac-mini-exit --accept-dns=false
fi

# 4. Detect this node's Tailscale IP, persist it back into secrets/mac.env.
MAC_TAILSCALE_IP="$(tailscale ip -4 | head -n1)"
[[ -n "$MAC_TAILSCALE_IP" ]] || die "Could not determine Tailscale IPv4. Is tailscale up?"
log "Mac mini Tailscale IP: $MAC_TAILSCALE_IP"
if grep -q '^MAC_TAILSCALE_IP=' "$SECRETS"; then
  sed -i '' "s|^MAC_TAILSCALE_IP=.*|MAC_TAILSCALE_IP=$MAC_TAILSCALE_IP|" "$SECRETS"
else
  echo "MAC_TAILSCALE_IP=$MAC_TAILSCALE_IP" >> "$SECRETS"
fi

# 5. Render sing-box config (sed avoids a gettext/envsubst dependency).
log "Rendering sing-box config..."
sed -e "s|\${MAC_TAILSCALE_IP}|$MAC_TAILSCALE_IP|g" \
    -e "s|\${MAC_VLESS_PORT}|$MAC_VLESS_PORT|g" \
    -e "s|\${MAC_VLESS_UUID}|$MAC_VLESS_UUID|g" \
    "$CONFIG_TPL" > "$CONFIG_OUT"
"$SINGBOX_BIN" check -c "$CONFIG_OUT" || die "sing-box config validation failed."

# 6. Render + install the LaunchDaemon.
mkdir -p "$LOG_DIR"
sed -e "s|\${SINGBOX_BIN}|$SINGBOX_BIN|g" \
    -e "s|\${SINGBOX_CONFIG}|$CONFIG_OUT|g" \
    -e "s|\${LOG_DIR}|$LOG_DIR|g" \
    "$PLIST_TPL" > "$PLIST_OUT"
log "Installing LaunchDaemon (sudo)..."
sudo cp "$PLIST_OUT" "$PLIST_DEST"
sudo chown root:wheel "$PLIST_DEST"
sudo chmod 644 "$PLIST_DEST"
sudo launchctl bootout system "$PLIST_DEST" 2>/dev/null || true
sudo launchctl bootstrap system "$PLIST_DEST"
sudo launchctl kickstart -k system/com.meshrouter.singbox

# 7. Power/availability hardening (a residential box must survive outages unattended).
log "Applying power settings (sudo)..."
sudo systemsetup -setrestartpowerfailure on  >/dev/null 2>&1 || log "  (could not set restart-on-power-failure; set it in System Settings > Energy)"
sudo systemsetup -setcomputersleep Never      >/dev/null 2>&1 || log "  (could not disable sleep; set 'Prevent automatic sleeping' in System Settings)"
sudo pmset -a autorestart 1 sleep 0           >/dev/null 2>&1 || true

log "Done."
echo
echo "  >> Copy this line into secrets/vps.env on the VPS side, then run the VPS bootstrap:"
echo "       MAC_TAILSCALE_IP=$MAC_TAILSCALE_IP"
echo
echo "  Check status:  sudo launchctl print system/com.meshrouter.singbox | grep state"
echo "  Logs:          tail -f $LOG_DIR/sing-box.err.log"
echo "  Also enable in System Settings: Energy > 'Start up automatically after power failure',"
echo "  and disable macOS automatic updates (defer to a manual window)."

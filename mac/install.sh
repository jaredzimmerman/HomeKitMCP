#!/bin/bash
# Installs HomeKit Bridge (your own signed app) for daily use, exposes it to the tailnet,
# and copies its token to the server that runs the MCP connector. Run it after building the app.
# Safe to run again. Changes only its own `tailscale serve` entry (tcp 8767); others stay.
#
#   bash install.sh [ssh-target-for-server]      e.g. root@my-server
# The SSH target can also be set as VPS_SSH in mac/config.local.sh (git-ignored).
# Without one, the token copy is skipped and you copy it yourself.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/config.local.sh" ] && . "$HERE/config.local.sh"
VPS_SSH="${1:-${VPS_SSH:-}}"
PORT=18767          # the app's loopback listener
TAILNET_PORT=8767   # what tailscale serve exposes; the VPS calls this
BUNDLE_ID="com.indigokarasu.HomeKitBridge"
DEST="/Applications/HomeKitBridge.app"
TOKEN="$HOME/.config/homekit-bridge/token"

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || die "run this on the Mac"

# ---- the app ---------------------------------------------------------------
# Prefer a Release build; fall back to the newest Debug build.
BUILT="$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/HomeKitBridge-*/Build/Products/Release-maccatalyst/HomeKitBridge.app 2>/dev/null | head -1 || true)"
[ -n "$BUILT" ] || BUILT="$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/HomeKitBridge-*/Build/Products/*-maccatalyst/HomeKitBridge.app 2>/dev/null | head -1 || true)"
if [ -n "$BUILT" ]; then
  say "Installing the build from Xcode into /Applications"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 2
  rm -rf "$DEST"
  ditto "$BUILT" "$DEST"
elif [ ! -d "$DEST" ]; then
  die "No build found. Build it first (see CLAUDE.md, Build and sign), then run this again."
fi
codesign --verify --deep "$DEST" || die "the app's signature does not verify"
codesign -d --entitlements - "$DEST" 2>/dev/null | grep -q homekit || die "the app was built without the HomeKit entitlement"

say "Starting HomeKit Bridge (menu bar only; it adds itself to Login Items on its first launch from /Applications)"
open "$DEST"

for _ in $(seq 1 30); do [ -s "$TOKEN" ] && curl -s "http://127.0.0.1:$PORT/healthz" | grep -q '"ok"' && break; sleep 1; done
[ -s "$TOKEN" ] || die "the app has not created its token yet; is it running? Allow Home access if macOS asks."
curl -s "http://127.0.0.1:$PORT/healthz" | grep -q '"ok"' || die "the app is not answering on 127.0.0.1:$PORT"

# ---- tailnet (sets the 8767 entry only; other serve entries stay) ---------
TS="$(command -v tailscale || true)"
[ -n "$TS" ] || TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
[ -x "$TS" ] || die "Tailscale CLI not found"
TS_IP="$("$TS" ip -4 | head -1)"
say "Exposing the bridge to the tailnet as port $TAILNET_PORT"
"$TS" serve --bg --tcp "$TAILNET_PORT" "tcp://localhost:$PORT"
"$TS" serve status 2>/dev/null | sed 's/^/   /' || true

# ---- token to the VPS ------------------------------------------------------
if [ -n "$VPS_SSH" ]; then
  say "Copying the token to $VPS_SSH:/etc/code-mcp/homekit.token"
  ssh -o ConnectTimeout=10 "$VPS_SSH" 'umask 077; mkdir -p /etc/code-mcp && cat > /etc/code-mcp/homekit.token && chmod 600 /etc/code-mcp/homekit.token' < "$TOKEN" \
    || echo "   Could not reach the server over SSH. The token stays at $TOKEN."
else
  say "No server given: copy $TOKEN to /etc/code-mcp/homekit.token (mode 600) on your server yourself"
fi

# ---- check -----------------------------------------------------------------
say "Checking HomeKit through the bridge"
AUTH="Authorization: Bearer $(cat "$TOKEN")"
CALL='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"homekit_status","arguments":{}}}'
curl -s -H "$AUTH" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
  -d "$CALL" "http://127.0.0.1:$PORT/mcp" | head -c 800; echo
echo "   Tailnet address for the VPS: http://$TS_IP:$TAILNET_PORT/mcp"

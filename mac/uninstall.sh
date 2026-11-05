#!/bin/bash
# Removes HomeKit Bridge from login, stops it, and closes its tailnet port (8767 only).
set -uo pipefail
osascript -e 'tell application id "com.indigokarasu.HomeKitBridge" to quit' >/dev/null 2>&1 || true
sleep 1
# Take it out of Login Items (registered by the app itself through SMAppService).
[ -x /Applications/HomeKitBridge.app/Contents/MacOS/HomeKitBridge ] \
  && /Applications/HomeKitBridge.app/Contents/MacOS/HomeKitBridge --remove-login-item >/dev/null 2>&1 || true
TS="$(command -v tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)"
"$TS" serve --tcp 8767 off 2>/dev/null || true
echo "Stopped. The app stays in /Applications; delete it and ~/.config/homekit-bridge/token to remove it fully."

# HomeKit MCP: notes for Claude Code

Project-specific, private details (servers, addresses, team ID, test accessory, house rules) go in
`CLAUDE.local.md`, which git ignores. Read it first if it exists.

## Layout
- `HomeKitBridge/HomeKitBridge/`: the Mac Catalyst app (Swift 5 language mode, iOS 17 target,
  unsandboxed, entitlement `com.apple.developer.homekit`).
  - `HomeKitBridgeApp.swift`: UIKit app delegate (no windows, `LSUIElement`), token file, login item
    (SMAppService; `HomeKitBridge --remove-login-item` removes it), menu status lines.
  - `HTTPServer.swift`: Network.framework listener on loopback port 18767, POST /mcp, GET /healthz,
    bearer token, Host check, 1 MB cap, 120 req/min. Reports listener failures and retries.
  - `MCPHandler.swift`: stateless MCP over Streamable HTTP with JSON responses.
  - `HomeStore.swift`: HMHomeManager, name/UUID resolution, event log, `HK.run`/`HK.make`
    completion-handler bridges, `Rollback` (undo steps for multi-step writes).
  - `Tools.swift`, `ToolDefinitions.swift`: the tools. `Names.swift`: friendly characteristic names.
  - `MenuBarProtocol.swift`: `HKBMenuBar`, compiled into both targets.
- `HomeKitBridge/MenuBarPlugin/`: native AppKit bundle the app loads from PlugIns (Catalyst cannot
  create an NSStatusItem). Owns the menu and keeps the launch scene's window invisible.
- `mac/`: install/uninstall on the Mac. `vps/`: the connector for a remote FastMCP server.
  `vps/homekit_tools.py` mirrors the bridge's tool signatures; keep them in sync.

## Building
- Run `xcodebuild` outside Claude Code's shell sandbox: inside it Xcode reports "No Accounts".
- Pass `DEVELOPMENT_TEAM=<team>` (the project leaves it empty).
- First signing for a new bundle ID: one `-destination 'generic/platform=iOS'` build registers the
  App ID with HomeKit; Catalyst builds sign after that.

## Things that look wrong but are deliberate
- Local port 18767, tailnet port 8767: Network.framework gets EADDRINUSE on a port `tailscale serve`
  holds, even on 127.0.0.1, so a shared port broke whenever Tailscale started first.
- The invisible 1x1 window: with no foreground scene HomeKit refuses every write (HMError 80) while
  reads keep working, so it fails quietly. Do not close or destroy the launch scene.
- `.atHome`/`.notAtHome` are aliases of `.firstEntry`/`.lastExit`; never list both in a dictionary
  literal (Swift traps on duplicate keys at runtime).

## Testing changes against a real home
Use one test accessory the owner names, `dry_run` first, put every change back, and delete any scene,
automation, room or group you create. Never call `remove_accessory` in tests.

```
TOKEN=$(cat ~/.config/homekit-bridge/token)
mcp() { curl -s -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}" \
  http://127.0.0.1:18767/mcp; echo; }
mcp homekit_status '{}'
```
Auth checks: no token gives 401, GET /mcp gives 405, a foreign Host header gives 403.

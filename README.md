# HomeKit MCP

Let Claude (or any MCP client) read and edit your Apple Home: rename accessories, move them between
rooms, change any writable setting, and manage rooms, zones, groups, scenes and automations.

Apple only exposes HomeKit to signed apps that hold the HomeKit entitlement, so the core of this
project is **HomeKit Bridge**, a small menu-bar-only Mac Catalyst app you build and sign with your own
Apple developer account. It serves HomeKit as an MCP server on the Mac's loopback interface. An
optional connector (`vps/homekit_tools.py`) lets a remote FastMCP server, such as one you already
connect to claude.ai, reach the bridge over Tailscale.

```
claude.ai ──> your FastMCP server (OAuth) ──> vps/homekit_tools.py
          ──> Tailscale (server -> Mac, tcp 8767)
          ──> `tailscale serve` on the Mac (tailnet 8767 -> localhost:18767)
          ──> HomeKit Bridge.app on 127.0.0.1:18767 (bearer token) ──> HomeKit
```

## Tools

| Tool | What it does |
|---|---|
| `homekit_status`, `homekit_device_map`, `homekit_rooms`, `homekit_events` | Read: permission and homes, the whole home at a glance, rooms, recent events |
| `homekit_accessories` | `list` / `search` / `get` (every service and characteristic with type, value, format, range, units, valid values) / `control` (write any characteristic HomeKit marks writable, by friendly name or type UUID; read back and verified) |
| `homekit_manage` | Rename accessories or single services, Display As, move accessories between rooms, rooms, zones, accessory groups, remove accessory |
| `homekit_scenes`, `homekit_scene_edit` | List, get, trigger; create, update, rename, delete |
| `homekit_automations` | List, get, create (button or state change), create_time, create_presence, edit, enable, disable, rename, delete; conditions (including presence), time windows (across midnight too), weekdays, auto turn-back |
| `homekit_home` | Home info (hub state, current user), users, rename home, add/remove home, primary home, add accessory (Apple's setup sheet). `discover` is not available on Mac |
| `homekit_devices` | Identify (blink), unblock, read one characteristic, `write_many` (validated as a batch before anything is written), change notifications, linked services, profiles |
| `homekit_cameras` | List, settings HomeKit exposes (for example microphone mute and volume), snapshot (capture date, or the JPEG with `image=true`) |
| `homekit_scene_actions` | Built-in scenes (Good Morning and friends), add or remove single actions in a scene |
| `homekit_triggers` | Full automations: several events (value, any change, range, button, time, sun, presence, location), end events, nested any/all/not conditions, execute once, several scenes; timer automations with recurrence; update in place |
| `homekit_history` | Local history of every device: status, devices, query, events, summaries (occupancy, on times, levels, activity, co-changes, automations), read-only SQL, pause/resume, snapshot_now, notify_now |
| `private_probe`, `private_homed_db` | Optional, undocumented HomeKit: see below |

Every write takes `dry_run`. Changes that need several HomeKit calls roll back the earlier steps if a
later one fails, and say what was put back. [COVERAGE.md](COVERAGE.md) maps each HomeKit API to its tool. Writes are logged to
`~/Library/Logs/homekit-bridge/actions.jsonl`.

Not reachable through Apple's public API: HomePod and Apple TV settings, Home app favorites, camera
recording options, firmware updates, and automations' hidden action sets.

## Requirements

- A Mac signed in to the iCloud account that owns (or is an admin of) your Home, macOS 14 or later.
- Xcode, and a paid Apple Developer account (the HomeKit entitlement needs a provisioning profile).
- For remote use: Tailscale on the Mac and on the server, and a Python FastMCP server whose
  `server.py` defines `mcp = FastMCP(...)` and `audit(tool, **kw)`.

## Build

1. Change `PRODUCT_BUNDLE_IDENTIFIER` (app and `MenuBarPlugin` targets) in
   `HomeKitBridge/HomeKitBridge.xcodeproj` and `BUNDLE_ID` in `mac/install.sh` to your own prefix.
2. Build and sign with your team ID:
   ```
   cd HomeKitBridge
   xcodebuild -project HomeKitBridge.xcodeproj -scheme HomeKitBridge \
     -destination 'platform=macOS,variant=Mac Catalyst' -configuration Release \
     -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM=<YOUR_TEAM_ID> build
   ```
   Xcode must be signed in to your developer account (Xcode > Settings > Accounts).
   If signing fails with "Entitlement com.apple.developer.homekit not found", run the same command
   once with `-destination 'generic/platform=iOS'`: that registers the App ID with the HomeKit
   capability, after which the Mac Catalyst build signs normally.
3. Launch the app once and allow Home access when macOS asks.

## Install on the Mac

```
bash mac/install.sh [ssh-target-of-your-server]
```

It copies the newest build to `/Applications`, starts it, runs
`tailscale serve --bg --tcp 8767 tcp://localhost:18767` (other serve entries stay), copies the bearer
token to `/etc/code-mcp/homekit.token` on your server over SSH (skipped if you give no target; you can
also set `VPS_SSH` in `mac/config.local.sh`), and checks `homekit_status`.

HomeKit Bridge lives in the menu bar (no Dock icon, no window). The menu shows status, homes,
accessory count and requests served, plus Start at Login, Show Activity Log in Finder, and Quit.
On its first launch from `/Applications` it adds itself to Login Items.

Allow your server to reach the Mac on tcp 8767 in your Tailscale access controls, for example:

```
{"src": ["tag:server"], "dst": ["tag:mac"], "ip": ["tcp:8767"]}
```

## Install the connector on your server

Copy `vps/` to the server and run, as root:

```
MAC_IP=<the Mac's Tailscale IPv4> bash vps/install-vps.sh
```

Optional settings: `CODE_MCP_DIR` (default `/opt/code-mcp`), `ENV_FILE` (default
`/etc/code-mcp.env`), `SERVICE` (default `code-mcp`), `PYTHON` (default `python3`), as environment
variables or in `vps/config.local.sh`. It backs up `server.py` and the env file, registers the tools,
and restarts the service.

Local MCP clients on the Mac can skip the server and call `http://127.0.0.1:18767/mcp` directly with
`Authorization: Bearer $(cat ~/.config/homekit-bridge/token)`.

## Security model

- Listens on loopback only; `tailscale serve` is the only way in from the network, and your tailnet
  access controls decide who can reach it.
- Bearer token in `~/.config/homekit-bridge/token` (mode 600), created on first launch.
- Host header check (localhost, 127.0.0.1, 100.x, `*.ts.net`), 1 MB body cap, 120 requests a minute.
- Every write supports `dry_run`; every write is logged on the Mac and, through `audit`, on the server.

## History logger

From 2.1 the bridge records every readable characteristic that sends change notifications, on every
home, into `~/Library/Application Support/homekit-bridge/history.sqlite`, so usage can be studied later
(for example to propose scenes and automations). It records changes as they happen (including the
bridge's own writes, which HomeKit does not report back), every 15 minutes a snapshot of the values
that differ from their last saved row, a full snapshot every 6 hours, a re-read of mains-powered
accessories every hour, and scene runs. Its only HomeKit write is switching change notifications on.

Noisy sensors are throttled when saved, always against the last saved value: CO2 on a move of 25 ppm,
light level on a 10% move (at least 1 lux), temperature on 0.2 °C, humidity on 1%. Air quality, ozone,
NO2, SO2, PM2.5, PM10 and VOC readings are saved only once a new value has held for 60 seconds (stamped
with the time it first appeared). Motion, occupancy, contact, power, brightness, color, outlets,
switches, buttons and the bridge's own writes are never throttled. `homekit_history status` shows how
many changes were skipped. Retention is unlimited; `homekit_history status` shows the size. The `sql` action accepts one SELECT, WITH or EXPLAIN statement
and stops any query after 15 seconds. Homes without a reachable home hub record nothing, and automation
runs are not recorded on a Mac (HMTrigger.lastFireDate is no longer supported there).

## Undocumented (private) HomeKit layer

Two tools reach past Apple's public API. Both are read-only unless you explicitly ask otherwise:

- `private_probe` lists HomeKit classes, describes objects, and reads declared properties. Its `call`
  action can invoke an arbitrary HomeKit selector, but it is a dry run unless you pass both
  `dry_run=false` and `confirm=true`, and homed rejects most private writes from apps without Apple's
  private entitlement.
- `private_homed_db` reads HomeKit's own database (read-only SQLite) for things the public API hides,
  such as Shortcut steps in automations. It only works after you give HomeKit Bridge **Full Disk
  Access** (System Settings > Privacy & Security). That grants the app read access to all your files,
  and the app is reachable from your tailnet with its token, so grant it only if you need this tool.

Nothing here needs, or should ever involve, turning off SIP, AMFI or other system protections.

## Notes and limits

- HomeKit refuses writes from a Catalyst app with no foreground scene ("Handler does not support
  background access"), so the app keeps an invisible, click-through 1x1 window instead of none.
  Writes while the screen is locked or the display is asleep have not been verified.
- HomeKit does not report an app's own writes back to it, so change notifications (`notify`) show up
  in `homekit_events` only for changes made elsewhere (the Home app, a switch, an automation).
- `activation_state` on automations is not a reliable on/off signal from a Mac (enabled automations
  can report `disabled`); use `enabled`.
- The app listens on 18767 rather than 8767 because Network.framework cannot listen on a port that
  `tailscale serve` already holds on the tailnet addresses.

## Uninstall

`bash mac/uninstall.sh` quits the app, removes it from Login Items, and turns off the tcp 8767
`tailscale serve` entry. Then delete `/Applications/HomeKitBridge.app` and `~/.config/homekit-bridge`.

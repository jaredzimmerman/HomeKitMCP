import Foundation

/// Schemas for the tools in ToolsMore.swift and PrivateTools.swift.
/// MCPHandler lists `ToolRouter.allDefinitions` (see PATCH.md).
extension ToolRouter {
    static var allDefinitions: [[String: Any]] { definitions + moreDefinitions }

    fileprivate static func s(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    fileprivate static func n(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
    fileprivate static func b(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
    fileprivate static func e(_ v: [String], _ d: String) -> [String: Any] { ["type": "string", "enum": v, "description": d] }
    fileprivate static func arr(_ d: String, _ items: [String: Any] = ["type": "object"]) -> [String: Any] {
        ["type": "array", "items": items, "description": d]
    }
    fileprivate static func t(_ name: String, _ desc: String, _ props: [String: Any], _ req: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": props]
        if !req.isEmpty { schema["required"] = req }
        return ["name": name, "description": desc, "inputSchema": schema]
    }

    static let moreDefinitions: [[String: Any]] = [
        t("homekit_home",
          "Home-level settings. info (every home: hub state, current user and whether they are an administrator, counts), users, manage_users (opens Apple's Manage Users sheet on the Mac for a person to use), rename_home, add_home, remove_home (deletes the home; needs confirm=true), set_primary (Apple deprecated it), add_accessory (opens Apple's setup on the Mac; macOS 27+; optional setup_url from the accessory's code), discover (unpaired accessories nearby for N seconds). dry_run previews writes.",
          ["action": e(["info", "users", "manage_users", "rename_home", "add_home", "remove_home", "set_primary", "add_accessory", "discover"], "Default info"),
           "home_id": s("Home UUID or name"), "name": s("add_home"), "new_name": s("rename_home"),
           "setup_url": s("X-HM:// setup payload URL (add_accessory)"), "seconds": n("discover, 3 to 60"),
           "confirm": b("Required for remove_home"), "dry_run": b("Preview only")]),
        t("homekit_devices",
          "Per-accessory operations. identify (blink/beep), unblock, read (live read of one characteristic with metadata), write_many (several writes in one call, each read back: rows {accessory, property, value, room?, service_name?, service_id?, service_index?}), notify (enable or disable change notifications so changes show in homekit_events), linked_services, profiles (bridge, Matter node id, network protection, camera, firmware, category). dry_run previews writes.",
          ["action": e(["identify", "unblock", "read", "write_many", "notify", "linked_services", "profiles"], "What to do"),
           "home_id": s("Home UUID or name"), "accessory_id": s("Accessory UUID or name"),
           "characteristic": s("Friendly name or type UUID (read, notify)"),
           "service_name": s("Pick one service"), "service_id": s("Pick one service by UUID"), "service_index": n("Pick a gang by label index"),
           "writes": arr("write_many rows"), "enable": b("notify: true (default) or false"),
           "verify": b("write_many: read back (default true)"), "dry_run": b("Preview only")], ["action"]),
        t("homekit_cameras",
          "Cameras. list, settings (night vision, rotation, mirroring, zoom, tilt, speaker and microphone mute and volume, last snapshot time), set (write one of those settings), snapshot (take a fresh one; image=true also returns an experimental JPEG that may be blank). Recording modes and activity zones are not in Apple's public API.",
          ["action": e(["list", "settings", "set", "snapshot"], "Default list"), "home_id": s("Home UUID or name"),
           "accessory_id": s("Camera accessory"), "setting": s("set: e.g. night_vision, speaker_volume, microphone_mute"),
           "value": s("set: value as a string"), "image": b("snapshot: include a JPEG"), "dry_run": b("Preview only")]),
        t("homekit_scene_actions",
          "Change a scene without replacing it. builtin (Apple's Wake Up, Sleep, Leave Home, Arrive Home scenes with their actions), add (append actions rows {accessory, property, value, room?, service_*?}), remove (drop every action on an accessory, optionally one property). dry_run previews.",
          ["action": e(["builtin", "add", "remove"], "What to do"), "home_id": s("Home UUID or name"),
           "scene": s("Scene name or UUID (add, remove)"), "actions": arr("add rows"),
           "accessory": s("remove: accessory name or UUID"), "property": s("remove: only this characteristic"),
           "dry_run": b("Preview only")], ["action"]),
        t("homekit_triggers",
          "Full automations. create_event: events (ANY one fires it) rows: {accessory, characteristic, value} | {accessory, characteristic, any_change:true} | {accessory, characteristic, min?, max?} (enters a range) | {button, press 0/1/2} | {time: HH:MM or sunset-30} | {presence: first_arrives|last_leaves|any_arrives|any_leaves, who: anyone|me} | {latitude, longitude, radius_m, on: enter|exit}. end_events turn it back: {duration_seconds} and/or characteristic rows. conditions (ALL must hold): {accessory, property, value, op} | {presence: anyone_home|nobody_home|me_home|me_away} | {any:[...]} | {all:[...]} | {not:{...}}; time_after/time_before (windows across midnight work); weekdays 1=Sun..7=Sat; execute_once; scene_ids (several) or inline actions. create_timer: fire_date ISO 8601 with zone, recurrence {every, unit: minute(>=5)|hour|day|week}. update: change events, end_events, conditions, time window, weekdays, execute_once, add_scenes, remove_scenes, new_name; for timers fire_date, recurrence. get shows activation state (e.g. disabled_no_home_hub). Enable, disable, rename, delete stay in homekit_automations. dry_run previews.",
          ["action": e(["get", "create_event", "create_timer", "update"], "What to do"), "home_id": s("Home UUID or name"),
           "id": s("Automation name or UUID (get, update)"), "name": s("New automation name"), "new_name": s("update"),
           "events": arr("Trigger events; any one fires"), "end_events": arr("Events that turn the actions back"),
           "conditions": arr("All must hold"), "time_after": s("HH:MM, sunrise, sunset, sunset-30"), "time_before": s("HH:MM, sunrise, sunset+15"),
           "weekdays": arr("1=Sun..7=Sat; [] for every day", ["type": "number"]), "execute_once": b("Run once, then disable"),
           "scene_id": s("One scene to run"), "scene_ids": arr("Scenes to run", ["type": "string"]), "actions": arr("Inline actions (a new scene)"),
           "add_scenes": arr("update", ["type": "string"]), "remove_scenes": arr("update", ["type": "string"]),
           "fire_date": s("create_timer/update: ISO 8601 with time zone"), "recurrence": ["type": "object", "description": "{every, unit}"] as [String: Any],
           "enabled": b("Enable on create (default true)"), "dry_run": b("Preview only")], ["action"]),
        t("private_probe",
          "Undocumented HomeKit (class-dumped headers). classes (HomeKit classes loaded), describe (properties and methods of an object), read (curated private properties per kind, or keys you name; path walks properties, e.g. path settings.rootGroup), call (invoke a selector; dry_run defaults to true; confirm=true needed; arguments may use @home, @accessory:<id>, @scene:<id>, @room:<id>, @automation:<id>). Missing selectors return errors, never crash. Most private writes are refused by homed without Apple's private entitlement. May break on any macOS update.",
          ["action": e(["classes", "describe", "read", "call"], "Default describe"),
           "kind": e(["manager", "home", "accessory", "service", "characteristic", "scene", "automation", "room", "zone", "group"], "Object kind (default home)"),
           "home_id": s("Home UUID or name"), "id": s("Object name or UUID (service: UUID)"),
           "characteristic": s("kind characteristic: friendly name or type UUID"), "service_id": s("kind characteristic: service UUID"),
           "path": s("Dot path of properties to walk first"), "keys": arr("read: property names", ["type": "string"]),
           "depth": n("read: 0 to 3, how deep to expand objects (default 1)"), "prefix": s("classes: default HM"),
           "selector": s("call: Objective-C selector"), "arguments": arr("call: arguments", [:]),
           "confirm": b("call: required"), "dry_run": b("call: default true")]),
        t("private_homed_db",
          "Read-only view of homed's own database (~/Library/HomeKit/core.sqlite), which holds what the public API hides, such as the steps of Shortcut-based automations. Needs Full Disk Access for HomeKit Bridge. tables, schema (table), query (one SELECT; blobs that are property lists are decoded), automation_actions (every action row, decoded). May lag the home hub; table names change between macOS versions.",
          ["action": e(["tables", "schema", "query", "automation_actions"], "Default tables"),
           "table": s("schema"), "sql": s("query: one SELECT"), "decode": b("query: decode plist blobs (default true)"),
           "limit": n("Max rows, default 100, max 1000")]),
    ]
}

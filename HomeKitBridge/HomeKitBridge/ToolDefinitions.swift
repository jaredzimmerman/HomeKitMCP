import Foundation

extension ToolRouter {
    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
    private static func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
    private static func oneOf(_ v: [String], _ d: String) -> [String: Any] { ["type": "string", "enum": v, "description": d] }
    private static func tool(_ name: String, _ desc: String, _ props: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": props]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": desc, "inputSchema": schema]
    }

    private static let home = str("Home UUID or name. Defaults to the primary home.")
    private static let serviceSelectors: [String: Any] = [
        "service_name": str("Name of one service, e.g. \"Switch 2\""),
        "service_id": str("UUID of one service (from homekit_accessories get)"),
        "service_index": num("Channel number of one service (service label index), e.g. 2"),
    ]
    private static func sel(_ p: [String: Any]) -> [String: Any] {
        p.merging(serviceSelectors) { a, _ in a }
    }

    private static var row: [String: Any] {
        var p: [String: Any] = [
            "accessory": str("Accessory UUID (preferred) or name"),
            "property": str("Characteristic: friendly name (power, brightness, ...) or type UUID"),
            "value": str("Target value as a string"),
            "room": str("Room name, to tell apart accessories with the same name"),
        ]
        serviceSelectors.forEach { p[$0.key] = $0.value }
        return ["type": "object", "properties": p, "required": ["accessory", "property", "value"]]
    }

    static let definitions: [[String: Any]] = [
        tool("homekit_status", "Bridge health: HomeKit permission, homes, accessory counts.", [:]),
        tool("homekit_device_map", "Whole home: zones, rooms, accessories, services, current state and which settings are writable. Start here.",
             ["home_id": home]),
        tool("homekit_rooms", "Rooms and their accessories.", ["home_id": home]),
        tool("homekit_events", "Recent events seen by the bridge: homes_updated, reachability_change, characteristic_change, accessory_controlled, scene_triggered.",
             ["limit": num("Max events, default 50"), "since": str("ISO 8601 time"),
              "type": oneOf(["homes_updated", "reachability_change", "characteristic_change", "accessory_controlled", "scene_triggered"], "Filter")]),
        tool("homekit_accessories",
             "Accessories. list (optionally by room), search (name/room/category/service type), get (every service and characteristic: type UUID, value, readable/writable, format, min/max/step, units, valid values; reads live values unless no_refresh), control (write one characteristic: any characteristic HomeKit marks writable, by friendly name or type UUID, so device settings too; read back and verified unless verify=false; dry_run previews).",
             sel(["action": oneOf(["list", "search", "get", "control"], "Default list"), "home_id": home,
              "room": str("Room filter (list)"), "accessory_id": str("Accessory UUID or name (get, control)"),
              "query": str("Search text"), "category": str("Category or service type filter (search)"),
              "characteristic": str("Friendly name or type UUID (control)"), "value": str("Value as a string, e.g. true, 40, locked (control)"),
              "verify": bool("Read back after writing (default true)"), "no_refresh": bool("Skip live reads (get)"),
              "dry_run": bool("Preview a control without writing")])),
        tool("homekit_manage",
             "Edit the home's structure. rename (accessory; or one service via a service UUID as id or service_* selectors), set_display_as (switch/outlet shown as light, fan, switch, outlet or default), assign_rooms (move accessories; missing rooms are created), create_room / rename_room / remove_room, create_zone / rename_zone / remove_zone / add_room_to_zone / remove_room_from_zone, list_groups / create_group / add_to_group / remove_from_group / rename_group / delete_group, remove_accessory (unpairs it; hard to undo). dry_run previews any of them.",
             sel(["action": oneOf(["rename", "set_display_as", "remove_accessory", "assign_rooms", "create_room", "rename_room", "remove_room",
                               "create_zone", "rename_zone", "remove_zone", "add_room_to_zone", "remove_room_from_zone",
                               "list_groups", "create_group", "add_to_group", "remove_from_group", "rename_group", "delete_group"], "What to do"),
              "home_id": home, "id": str("Accessory, service, room or zone name/UUID"), "new_name": str("New name"),
              "display_as": oneOf(["light", "fan", "switch", "outlet", "default"], "set_display_as"),
              "name": str("Name for create_room, create_zone, create_group"), "group": str("Group name/UUID"),
              "members": ["type": "array", "items": ["type": "string"], "description": "Accessory or service names/UUIDs"] as [String: Any],
              "room": str("Room name/UUID (zone membership)"), "zone": str("Zone name/UUID"),
              "assignments": ["type": "array", "description": "[{uuid or accessory, room}]",
                              "items": ["type": "object", "properties": ["uuid": str("Accessory UUID"), "accessory": str("Accessory name"),
                                                                         "room": str("Target room (created if missing)")],
                                        "required": ["room"]] as [String: Any]] as [String: Any],
              "dry_run": bool("Preview only")]),
             required: ["action"]),
        tool("homekit_scenes", "Scenes: list, get (every action), trigger (run now).",
             ["action": oneOf(["list", "get", "trigger"], "Default list"), "home_id": home, "scene_id": str("Scene name or UUID")]),
        tool("homekit_scene_edit",
             "Create, replace, rename or delete a scene. update replaces the whole action list and keeps the scene's UUID, so automations that run it keep working. dry_run previews.",
             ["action": oneOf(["create", "update", "rename", "delete"], "What to do"), "scene": str("Scene name (create) or name/UUID"),
              "new_name": str("rename"), "actions": ["type": "array", "items": row, "description": "Scene actions (create, update)"] as [String: Any],
              "home_id": home, "dry_run": bool("Preview only")],
             required: ["action", "scene"]),
        tool("homekit_automations",
             "Automations. list / get. Triggers: create (accessory_id + press_type 0 single, 1 double, 2 long for buttons, or accessory_id + characteristic + trigger_value for sensors and state changes), create_time (time HH:MM, sunrise, sunset, sunset-30, sunrise+15), create_presence (presence first_arrives, last_leaves, any_arrives, any_leaves; presence_who me or anyone). Each runs scene_id or makes a scene from actions rows. Gates, all ANDed: weekdays (1=Sun..7=Sat); conditions rows (accessory + property + value, op ==, !=, >, >=, <, <=; or {presence: anyone_home, nobody_home, me_home, me_away}); time_after / time_before (HH:MM or sunrise/sunset with offset; a window crossing midnight such as sunset to sunrise works). duration_seconds turns the actions back after that long. edit changes an automation in place, keeping its UUID: pass only what changes (time, presence or accessory trigger; conditions and time window, which are rebuilt together from what you pass; weekdays, [] for every day; duration_seconds or clear_duration; new_name). enable / disable / rename / delete. dry_run previews.",
             sel(["action": oneOf(["list", "get", "create", "create_time", "create_presence", "edit", "enable", "disable", "rename", "delete"], "Default list"),
              "home_id": home, "id": str("Automation name or UUID"), "name": str("Name for a new automation"), "new_name": str("New name (rename, edit)"),
              "accessory_id": str("Trigger accessory (create)"), "characteristic": str("Trigger characteristic (create)"),
              "trigger_value": str("Value that fires it (create)"), "press_type": num("Button press 0, 1 or 2 (create)"),
              "time": str("HH:MM, sunrise, sunset, sunset-30 (create_time)"),
              "presence": oneOf(["first_arrives", "last_leaves", "any_arrives", "any_leaves"], "create_presence"),
              "presence_who": oneOf(["anyone", "me"], "Whose arrival or departure (default anyone)"),
              "scene_id": str("Scene to run"),
              "actions": ["type": "array", "items": row, "description": "Inline actions instead of scene_id"] as [String: Any],
              "conditions": ["type": "array", "description": "Only run when all hold",
                             "items": ["type": "object", "properties": [
                                "accessory": str("Accessory UUID or name"), "property": str("Characteristic"),
                                "value": str("Value as a string"), "op": oneOf(["==", "!=", ">", ">=", "<", "<="], "Default =="),
                                "room": str("Room, to tell apart same-named accessories"),
                                "presence": oneOf(["anyone_home", "nobody_home", "me_home", "me_away"], "Use instead of accessory/property/value"),
                             ]] as [String: Any]] as [String: Any],
              "time_after": str("Only after this time: HH:MM, sunrise, sunset, sunset-30"),
              "time_before": str("Only before this time: HH:MM, sunrise, sunset, sunrise+15"),
              "duration_seconds": num("Turn the actions back after this many seconds (1 to 86400)"),
              "clear_duration": bool("Remove the turn-back (edit)"),
              "weekdays": ["type": "array", "items": ["type": "number"], "description": "1=Sun..7=Sat"] as [String: Any],
              "dry_run": bool("Preview only")])),
    ]
}

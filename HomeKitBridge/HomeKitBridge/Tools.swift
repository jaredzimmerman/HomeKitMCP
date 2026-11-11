import Foundation
import HomeKit

/// The MCP tools. Each returns a JSON-able value or throws a readable error.
@MainActor
final class ToolRouter {
    let store: HomeStore
    init(store: HomeStore) { self.store = store }

    func call(name: String, args: [String: Any]) async throws -> Any {
        if name != "homekit_status" && name != "homekit_events" { try await store.waitUntilLoaded() }
        let a = Args(args)
        do {
            let result: Any
            switch name {
            case "homekit_status": result = status()
            case "homekit_events": result = events(a)
            case "homekit_rooms": result = try rooms(a)
            case "homekit_device_map": result = try deviceMap(a)
            case "homekit_accessories": result = try await accessories(a)
            case "homekit_manage": result = try await manage(a)
            case "homekit_scenes": result = try await scenes(a)
            case "homekit_scene_edit": result = try await sceneEdit(a)
            case "homekit_automations": result = try await automations(a)
            case "homekit_history": result = try await History.shared.tool(a)
            default: result = try await callMore(name: name, a: a, raw: args)
            }
            if a.isWrite(tool: name) { Audit.write(tool: name, args: args, ok: true, error: nil) }
            return result
        } catch {
            if a.isWrite(tool: name) { Audit.write(tool: name, args: args, ok: false, error: "\(error)") }
            throw error
        }
    }

    /// HomeKit throws an Objective-C exception (which kills the app) when an automation event uses a
    /// characteristic that does not send change notifications, so check before building one.
    func requireNotifying(_ c: HMCharacteristic, _ accessoryName: String) throws {
        guard c.properties.contains(HMCharacteristicPropertySupportsEventNotification) else {
            throw BridgeError.message("\(Names.name(for: c.characteristicType)) on \(accessoryName) does not send change notifications, so it cannot start or end an automation")
        }
    }

    // MARK: status, events

    func status() -> Any {
        let homes = store.manager.homes
        return [
            "version": BridgeConfig.version,
            "homekit_access": store.authorizationText,
            "homes": homes.map { ["name": $0.name, "id": $0.uniqueIdentifier.uuidString, "primary": $0.isPrimary,
                                  "accessories": $0.accessories.count, "rooms": $0.rooms.count] as [String: Any] },
        ] as [String: Any]
    }

    func events(_ a: Args) -> Any {
        var list = store.events
        if let type = a.str("type") { list = list.filter { ($0["type"] as? String) == type } }
        if let since = a.str("since") { list = list.filter { (($0["time"] as? String) ?? "") > since } }
        let limit = a.int("limit") ?? 50
        return Array(list.suffix(max(1, limit)))
    }

    // MARK: reading

    func rooms(_ a: Args) throws -> Any {
        let home = try store.home(a.str("home_id"))
        return (home.rooms + [home.roomForEntireHome()]).map { room in
            ["name": room.name, "id": room.uniqueIdentifier.uuidString,
             "accessories": room.accessories.map { ["name": $0.name, "id": $0.uniqueIdentifier.uuidString] }] as [String: Any]
        }
    }

    func deviceMap(_ a: Args) throws -> Any {
        let home = try store.home(a.str("home_id"))
        let zoneOf: [UUID: [String]] = home.zones.reduce(into: [:]) { acc, z in
            for r in z.rooms { acc[r.uniqueIdentifier, default: []].append(z.name) }
        }
        let rooms = (home.rooms + [home.roomForEntireHome()]).filter { !$0.accessories.isEmpty }
        return [
            "home": home.name,
            "home_id": home.uniqueIdentifier.uuidString,
            "zones": home.zones.map { ["name": $0.name, "id": $0.uniqueIdentifier.uuidString, "rooms": $0.rooms.map(\.name)] as [String: Any] },
            "rooms": rooms.map { room in
                [
                    "name": room.name,
                    "id": room.uniqueIdentifier.uuidString,
                    "zones": zoneOf[room.uniqueIdentifier] ?? [],
                    "accessories": room.accessories.map { acc in
                        [
                            "name": acc.name,
                            "id": acc.uniqueIdentifier.uuidString,
                            "category": acc.category.localizedDescription,
                            "reachable": acc.isReachable,
                            "services": userServices(acc).map { s in
                                [
                                    "name": s.name,
                                    "id": s.uniqueIdentifier.uuidString,
                                    "type": Names.serviceName(for: s.serviceType),
                                    "displayed_as": s.associatedServiceType.map(Names.serviceName(for:)) as Any,
                                    "state": stateSummary(s),
                                    "writable": s.characteristics.filter(isWritable).map { Names.name(for: $0.characteristicType) },
                                ] as [String: Any]
                            },
                        ] as [String: Any]
                    },
                ] as [String: Any]
            },
            "scenes": home.actionSets.map(\.name),
            "groups": home.serviceGroups.map(\.name),
        ] as [String: Any]
    }

    func accessories(_ a: Args) async throws -> Any {
        let home = try store.home(a.str("home_id"))
        switch a.str("action") ?? "list" {
        case "list":
            var list = home.accessories
            if let roomKey = a.str("room") {
                let room = try store.room(roomKey, in: home)
                list = list.filter { $0.room?.uniqueIdentifier == room.uniqueIdentifier }
            }
            return list.map { summary($0) }
        case "search":
            let q = (a.str("query") ?? "").lowercased()
            let cat = a.str("category")?.lowercased()
            return home.accessories.filter { acc in
                let hay = ([acc.name, acc.room?.name ?? "", acc.category.localizedDescription]
                           + acc.services.map(\.name) + acc.services.map { Names.serviceName(for: $0.serviceType) })
                    .joined(separator: " ").lowercased()
                let catOK = cat == nil || acc.category.localizedDescription.lowercased().contains(cat!)
                    || acc.services.contains { Names.serviceName(for: $0.serviceType) == cat! }
                return (q.isEmpty || hay.contains(q)) && catOK
            }.map { summary($0) }
        case "get":
            let acc = try store.accessory(try a.req("accessory_id"), in: home)
            var refreshed = false
            var failed = 0
            if !(a.bool("no_refresh") ?? false) && acc.isReachable {
                for s in acc.services {
                    for c in s.characteristics where c.properties.contains(HMCharacteristicPropertyReadable) {
                        do { try await HK.run { c.readValue(completionHandler: $0) } } catch { failed += 1 }
                    }
                }
                refreshed = true
            }
            var d = summary(acc)
            d["refreshed"] = refreshed
            if failed > 0 { d["failed_reads"] = failed }
            d["manufacturer"] = acc.manufacturer as Any
            d["model"] = acc.model as Any
            d["firmware"] = acc.firmwareVersion as Any
            d["bridged"] = acc.isBridged
            d["services"] = acc.services.map { serviceDetail($0) }
            return d
        case "control":
            let acc = try store.accessory(try a.req("accessory_id"), in: home)
            let key = try a.req("characteristic")
            let raw = try a.req("value")
            let (service, c) = try findCharacteristic(acc, key, a)
            guard c.properties.contains(HMCharacteristicPropertyWritable) else {
                throw BridgeError.message("\(key) on \(acc.name) / \(service.name) is not writable")
            }
            guard acc.isReachable else { throw BridgeError.message("\(acc.name) is not reachable") }
            let value = try Names.parse(raw, for: c)
            let before = JSONValue.sanitize(c.value ?? NSNull())
            let sensitive = Sensitive.names([c])
            if a.bool("dry_run") == true {
                var out: [String: Any] = ["dry_run": true, "accessory": acc.name, "service": service.name,
                        "characteristic": Names.name(for: c.characteristicType), "current": before, "new": JSONValue.sanitize(value)]
                if !sensitive.isEmpty { out["needs_confirm"] = Sensitive.note }
                return out
            }
            try Sensitive.require(sensitive, a)
            try await HK.run { c.writeValue(value, completionHandler: $0) }
            store.log("accessory_controlled", ["accessory": acc.name, "service": service.name,
                                               "characteristic": Names.name(for: c.characteristicType), "value": raw])
            var out: [String: Any] = ["ok": true, "accessory": acc.name, "service": service.name,
                                      "characteristic": Names.name(for: c.characteristicType), "previous": before,
                                      "value": JSONValue.sanitize(value)]
            if (a.bool("verify") ?? true) && c.properties.contains(HMCharacteristicPropertyReadable) {
                try? await HK.run { c.readValue(completionHandler: $0) }
                // The write already succeeded, so report a mismatch instead of throwing (a throw would
                // tell the caller nothing changed when the home did).
                let same = Names.same(c.value, value)
                out["verified"] = same
                if !same {
                    out["reads"] = JSONValue.sanitize(c.value ?? NSNull())
                    out["note"] = "Write accepted but the device reads a different value (it may be off, or rounds values)."
                }
            }
            // HomeKit does not report this app's own writes back to it, so record the new value here.
            History.shared.change(acc, service, c, byBridge: true)
            return out
        default:
            throw BridgeError.message("action must be list, search, get or control")
        }
    }

    // MARK: structure

    func manage(_ a: Args) async throws -> Any {
        let home = try store.home(a.str("home_id"))
        let dry = a.bool("dry_run") ?? false
        let action = try a.req("action")
        func done(_ what: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            var d = extra
            d[dry ? "would" : "done"] = what
            if dry { d["dry_run"] = true }
            return d
        }

        switch action {
        case "rename":
            let id = try a.req("id")
            let newName = try a.req("new_name")
            if let hit = store.service(uuid: id, in: home) {
                let (acc, s) = hit
                let label = "\(acc.name) / \(s.name)"   // read before the write so the message shows the old name
                if !dry { try await HK.run { s.updateName(newName, completionHandler: $0) } }
                return done("rename service \(label) to \(newName)")
            }
            let acc = try store.accessory(id, in: home)
            if a.hasServiceSelector {
                let s = try pickService(acc, a)
                let label = "\(acc.name) / \(s.name)"
                if !dry { try await HK.run { s.updateName(newName, completionHandler: $0) } }
                return done("rename service \(label) to \(newName)")
            }
            let oldName = acc.name
            if !dry { try await HK.run { acc.updateName(newName, completionHandler: $0) } }
            return done("rename accessory \(oldName) to \(newName)")

        case "set_display_as":
            let id = try a.req("id")
            let as_ = try a.req("display_as")
            let target: (HMAccessory, HMService)
            if let hit = store.service(uuid: id, in: home) { target = hit } else {
                let found = try store.accessory(id, in: home)
                target = (found, try pickService(found, a, prefer: [HMServiceTypeSwitch, HMServiceTypeOutlet]))
            }
            let (acc, s) = target
            guard s.serviceType == HMServiceTypeSwitch || s.serviceType == HMServiceTypeOutlet else {
                throw BridgeError.message("Only switch and outlet services can change Display As")
            }
            var type = Names.serviceType(for: as_)
            if type == s.serviceType { type = nil }
            if !dry { try await HK.run { s.updateAssociatedServiceType(type, completionHandler: $0) } }
            return done("show \(acc.name) / \(s.name) as \(as_)")

        case "remove_accessory":
            let acc = try store.accessory(try a.req("id"), in: home)
            if !dry { try await HK.run { home.removeAccessory(acc, completionHandler: $0) } }
            return done("remove accessory \(acc.name) from \(home.name)")

        case "assign_rooms":
            guard let rows = a.dicts("assignments"), !rows.isEmpty else {
                throw BridgeError.message("assignments is required: [{\"uuid\" or \"accessory\", \"room\"}]")
            }
            var results: [[String: Any]] = []
            let undo = Rollback()   // all or nothing: a failing row puts earlier moves and new rooms back
            do {
                for row in rows {
                    guard let roomName = row["room"] as? String, !roomName.isEmpty else { throw BridgeError.message("each assignment needs room") }
                    guard let key = (row["uuid"] as? String) ?? (row["accessory"] as? String) else {
                        throw BridgeError.message("each assignment needs uuid or accessory")
                    }
                    let acc = try store.accessory(key, in: home)
                    // Create the room only when no room has that name; an ambiguous name is an error.
                    var room: HMRoom? = store.roomExists(roomName, in: home) ? try store.room(roomName, in: home) : nil
                    var created = false
                    if room == nil {
                        created = true
                        if !dry {
                            let made: HMRoom = try await HK.make { home.addRoom(withName: roomName, completionHandler: $0) }
                            undo.add("removed new room \(roomName)") { try await HK.run { home.removeRoom(made, completionHandler: $0) } }
                            room = made
                        }
                    }
                    if acc.room?.uniqueIdentifier == room?.uniqueIdentifier && room != nil {
                        results.append(["accessory": acc.name, "room": roomName, "result": "already there"]); continue
                    }
                    let from = acc.room?.name   // read before the move
                    let fromRoom = acc.room ?? home.roomForEntireHome()
                    if !dry, let room {
                        try await HK.run { home.assignAccessory(acc, to: room, completionHandler: $0) }
                        undo.add("moved \(acc.name) back to \(fromRoom.name)") {
                            try await HK.run { home.assignAccessory(acc, to: fromRoom, completionHandler: $0) }
                        }
                    }
                    results.append(["accessory": acc.name, "from": from as Any, "room": roomName,
                                     "room_created": created, "result": dry ? "would move" : "moved"])
                }
            } catch {
                throw await undo.unwind(after: error)
            }
            return ["dry_run": dry, "assignments": results] as [String: Any]

        case "create_room":
            let n = try a.req("name")
            if !dry { _ = try await HK.make { home.addRoom(withName: n, completionHandler: $0) } as HMRoom }
            return done("create room \(n)")
        case "rename_room":
            let room = try store.room(try a.req("id"), in: home)
            let n = try a.req("new_name")
            if !dry { try await HK.run { room.updateName(n, completionHandler: $0) } }
            return done("rename room \(room.name) to \(n)")
        case "remove_room":
            let room = try store.room(try a.req("id"), in: home)
            let roomName = room.name, moved = room.accessories.map(\.name)   // read before removal empties them
            if !dry { try await HK.run { home.removeRoom(room, completionHandler: $0) } }
            return done("remove room \(roomName) (its accessories go to the default room)", ["accessories": moved])

        case "create_zone":
            let n = try a.req("name")
            if !dry { _ = try await HK.make { home.addZone(withName: n, completionHandler: $0) } as HMZone }
            return done("create zone \(n)")
        case "rename_zone":
            let zone = try store.zone(try a.req("id"), in: home)
            let n = try a.req("new_name")
            if !dry { try await HK.run { zone.updateName(n, completionHandler: $0) } }
            return done("rename zone \(zone.name) to \(n)")
        case "remove_zone":
            let zone = try store.zone(try a.req("id"), in: home)
            if !dry { try await HK.run { home.removeZone(zone, completionHandler: $0) } }
            return done("remove zone \(zone.name)")
        case "add_room_to_zone", "remove_room_from_zone":
            let zone = try store.zone(try a.req("zone"), in: home)
            let room = try store.room(try a.req("room"), in: home)
            if !dry {
                if action == "add_room_to_zone" { try await HK.run { zone.addRoom(room, completionHandler: $0) } }
                else { try await HK.run { zone.removeRoom(room, completionHandler: $0) } }
            }
            return done("\(action == "add_room_to_zone" ? "add" : "remove") room \(room.name) \(action == "add_room_to_zone" ? "to" : "from") zone \(zone.name)")

        case "list_groups":
            return home.serviceGroups.map { g in
                ["name": g.name, "id": g.uniqueIdentifier.uuidString,
                 "members": g.services.map { ["accessory": $0.accessory?.name ?? "", "service": $0.name, "service_id": $0.uniqueIdentifier.uuidString] }] as [String: Any]
            }
        case "create_group":
            let n = try a.req("name")
            let services = try members(a, home)
            if !dry {
                let g: HMServiceGroup = try await HK.make { home.addServiceGroup(withName: n, completionHandler: $0) }
                let undo = Rollback()
                undo.add("removed new group \(n)") { try await HK.run { home.removeServiceGroup(g, completionHandler: $0) } }
                do {
                    for s in services { try await HK.run { g.addService(s, completionHandler: $0) } }
                } catch {
                    throw await undo.unwind(after: error)
                }
            }
            return done("create group \(n)", ["members": services.map(\.name)])
        case "add_to_group", "remove_from_group":
            let g = try store.group(try a.req("group"), in: home)
            let services = try members(a, home)
            if !dry {
                let undo = Rollback()
                do {
                    for s in services {
                        if action == "add_to_group" {
                            try await HK.run { g.addService(s, completionHandler: $0) }
                            undo.add("took \(s.name) back out of \(g.name)") { try await HK.run { g.removeService(s, completionHandler: $0) } }
                        } else {
                            try await HK.run { g.removeService(s, completionHandler: $0) }
                            undo.add("put \(s.name) back in \(g.name)") { try await HK.run { g.addService(s, completionHandler: $0) } }
                        }
                    }
                } catch {
                    throw await undo.unwind(after: error)
                }
            }
            return done("\(action == "add_to_group" ? "add to" : "remove from") group \(g.name)", ["members": services.map(\.name)])
        case "rename_group":
            let g = try store.group(try a.req("group"), in: home)
            let n = try a.req("new_name")
            if !dry { try await HK.run { g.updateName(n, completionHandler: $0) } }
            return done("rename group \(g.name) to \(n)")
        case "delete_group":
            let g = try store.group(try a.req("group"), in: home)
            if !dry { try await HK.run { home.removeServiceGroup(g, completionHandler: $0) } }
            return done("delete group \(g.name) (accessories stay)")
        default:
            throw BridgeError.message("Unknown manage action: \(action)")
        }
    }

    func members(_ a: Args, _ home: HMHome) throws -> [HMService] {
        guard let keys = a.strings("members"), !keys.isEmpty else { throw BridgeError.message("members is required") }
        return try keys.map { key -> HMService in
            if let hit = store.service(uuid: key, in: home) { return hit.1 }
            let acc = try store.accessory(key, in: home)
            let candidates = userServices(acc).filter { $0.characteristics.contains(where: isWritable) }
            guard candidates.count == 1 else {
                let list = candidates.map { "\($0.name) = \($0.uniqueIdentifier.uuidString)" }.joined(separator: "; ")
                throw BridgeError.message("\(acc.name) has several controllable services; pass a service UUID: \(list)")
            }
            return candidates[0]
        }
    }

    // MARK: scenes

    func scenes(_ a: Args) async throws -> Any {
        let home = try store.home(a.str("home_id"))
        switch a.str("action") ?? "list" {
        case "list":
            return home.actionSets.map { ["name": $0.name, "id": $0.uniqueIdentifier.uuidString,
                                          "type": sceneType($0), "actions": $0.actions.count] as [String: Any] }
        case "get":
            let s = try store.scene(try a.req("scene_id"), in: home)
            return ["name": s.name, "id": s.uniqueIdentifier.uuidString, "type": sceneType(s),
                    "last_run": s.lastExecutionDate as Any, "actions": s.actions.compactMap(actionRow)] as [String: Any]
        case "trigger":
            let s = try store.scene(try a.req("scene_id"), in: home)
            let sensitive = Sensitive.names(sets: [s])
            if a.bool("dry_run") == true {
                var out: [String: Any] = ["dry_run": true, "would": "run scene \(s.name)", "actions": s.actions.compactMap(actionRow)]
                if !sensitive.isEmpty { out["needs_confirm"] = Sensitive.note }
                return out
            }
            try Sensitive.require(sensitive, a)
            try await HK.run(timeout: 60) { home.executeActionSet(s, completionHandler: $0) }
            store.log("scene_triggered", ["scene": s.name])
            return ["ok": true, "scene": s.name] as [String: Any]
        default:
            throw BridgeError.message("action must be list, get or trigger")
        }
    }

    func sceneEdit(_ a: Args) async throws -> Any {
        let home = try store.home(a.str("home_id"))
        let dry = a.bool("dry_run") ?? false
        let key = try a.req("scene")
        switch try a.req("action") {
        case "create":
            let writes = try writeActions(a.dicts("actions"), home)
            let sensitive = Sensitive.names(writes.map(\.0.characteristic))
            if dry { return Sensitive.flag(["dry_run": true, "would": "create scene \(key)", "actions": writes.map(\.1)], sensitive) }
            try Sensitive.require(sensitive, a)
            let set: HMActionSet = try await HK.make { home.addActionSet(withName: key, completionHandler: $0) }
            let undo = Rollback()
            undo.add("removed new scene \(key)") { try await HK.run { home.removeActionSet(set, completionHandler: $0) } }
            do {
                for (w, _) in writes { try await HK.run { set.addAction(w, completionHandler: $0) } }
            } catch {
                throw await undo.unwind(after: error)
            }
            return ["ok": true, "scene": set.name, "id": set.uniqueIdentifier.uuidString, "actions": writes.count] as [String: Any]
        case "update":
            let set = try store.scene(key, in: home)
            let writes = try writeActions(a.dicts("actions"), home)
            let sensitive = Sensitive.names(writes.map(\.0.characteristic))
            if dry { return Sensitive.flag(["dry_run": true, "would": "replace the actions of \(set.name)", "before": set.actions.compactMap(actionRow), "after": writes.map(\.1)], sensitive) }
            try Sensitive.require(sensitive, a)
            // HomeKit allows one action per characteristic in a scene, so the old actions go first;
            // if any new one is refused, the new ones come out and the old ones are recreated.
            let undo = Rollback()
            do {
                for old in Array(set.actions) {
                    try await HK.run { set.removeAction(old, completionHandler: $0) }
                    if let w = old as? HMCharacteristicWriteAction<NSCopying> {
                        let c = w.characteristic, v = w.targetValue
                        undo.add("restored an old action") {
                            try await HK.run { set.addAction(HMCharacteristicWriteAction<NSCopying>(characteristic: c, targetValue: v), completionHandler: $0) }
                        }
                    } else {
                        undo.add("restored an old action") { throw BridgeError.message("not a characteristic write; re-add it in the Home app") }
                    }
                }
                for (w, _) in writes {
                    try await HK.run { set.addAction(w, completionHandler: $0) }
                    undo.add("removed a new action") { try await HK.run { set.removeAction(w, completionHandler: $0) } }
                }
            } catch {
                throw await undo.unwind(after: error)
            }
            return ["ok": true, "scene": set.name, "id": set.uniqueIdentifier.uuidString, "actions": writes.count] as [String: Any]
        case "rename":
            let set = try store.scene(key, in: home)
            let n = try a.req("new_name")
            if !dry { try await HK.run { set.updateName(n, completionHandler: $0) } }
            return [dry ? "would" : "done": "rename scene \(set.name) to \(n)"]
        case "delete":
            let set = try store.scene(key, in: home)
            if !dry { try await HK.run { home.removeActionSet(set, completionHandler: $0) } }
            return [dry ? "would" : "done": "delete scene \(set.name)"]
        default:
            throw BridgeError.message("action must be create, update, rename or delete")
        }
    }

    func writeActions(_ rows: [[String: Any]]?, _ home: HMHome) throws -> [(HMCharacteristicWriteAction<NSCopying>, [String: Any])] {
        guard let rows, !rows.isEmpty else { throw BridgeError.message("actions is required") }
        return try rows.map { row -> (HMCharacteristicWriteAction<NSCopying>, [String: Any]) in
            let r = Args(row)
            var accHome = home.accessories
            if let roomKey = r.str("room") {
                accHome = accHome.filter { $0.room?.name.caseInsensitiveCompare(roomKey) == .orderedSame }
            }
            let accKey = try r.req("accessory")
            let acc = try store.pick(accHome, accKey, kind: "accessory", id: \.uniqueIdentifier, name: \.name)
            let prop = try r.str("property") ?? r.req("characteristic")
            let (service, c) = try findCharacteristic(acc, prop, r)
            let value = try Names.parse(try r.req("value"), for: c)
            let action = HMCharacteristicWriteAction<NSCopying>(characteristic: c, targetValue: copying(value))
            return (action, ["accessory": acc.name, "service": service.name, "property": Names.name(for: c.characteristicType),
                             "value": JSONValue.sanitize(value)])
        }
    }

    // MARK: automations

    func automations(_ a: Args) async throws -> Any {
        let home = try store.home(a.str("home_id"))
        let dry = a.bool("dry_run") ?? false
        let action = a.str("action") ?? "list"
        switch action {
        case "list":
            return home.triggers.map { triggerDict($0, detail: false) }
        case "get":
            return triggerDict(try store.trigger(try a.req("id"), in: home), detail: true)
        case "enable", "disable":
            let t = try store.trigger(try a.req("id"), in: home)
            if !dry && action == "enable" { try Sensitive.require(Sensitive.names(sets: t.actionSets), a) }
            if !dry { try await HK.run { t.enable(action == "enable", completionHandler: $0) } }
            return [dry ? "would" : "done": "\(action) \(t.name)"]
        case "rename":
            let t = try store.trigger(try a.req("id"), in: home)
            let n = try a.req("new_name")
            if !dry { try await HK.run { t.updateName(n, completionHandler: $0) } }
            return [dry ? "would" : "done": "rename automation \(t.name) to \(n)"]
        case "delete":
            let t = try store.trigger(try a.req("id"), in: home)
            if !dry { try await HK.run { home.removeTrigger(t, completionHandler: $0) } }
            return [dry ? "would" : "done": "delete automation \(t.name)"]
        case "create", "create_time", "create_presence":
            let name = try a.req("name")
            let (event, describe) = try triggerEvent(action, a, home)
            let recurrences = weekdayComponents(a)
            let predicate = try buildPredicate(a, home)
            let endEvents = try durationEvents(a)
            var scene: HMActionSet? = nil
            var writes: [(HMCharacteristicWriteAction<NSCopying>, [String: Any])] = []
            if let sceneKey = a.str("scene_id") { scene = try store.scene(sceneKey, in: home) }
            else { writes = try writeActions(a.dicts("actions"), home) }
            let sensitive = scene.map { Sensitive.names(sets: [$0]) } ?? Sensitive.names(writes.map(\.0.characteristic))
            if dry {
                return Sensitive.flag(["dry_run": true, "would": "create automation \(name): when \(describe)",
                        "only_if": predicate?.predicateFormat ?? "always", "auto_revert_seconds": a.int("duration_seconds") as Any,
                        "runs": scene?.name ?? "new scene \(name)", "actions": writes.map(\.1),
                        "weekdays": a.ints("weekdays") ?? []], sensitive)
            }
            try Sensitive.require(sensitive, a)
            let undo = Rollback()
            do {
                if scene == nil {
                    let set: HMActionSet = try await HK.make { home.addActionSet(withName: name, completionHandler: $0) }
                    undo.add("removed new scene \(name)") { try await HK.run { home.removeActionSet(set, completionHandler: $0) } }
                    for (w, _) in writes { try await HK.run { set.addAction(w, completionHandler: $0) } }
                    scene = set
                }
                let trigger = HMEventTrigger(name: name, events: [event], end: endEvents,
                                             recurrences: recurrences, predicate: predicate)
                try await HK.run { home.addTrigger(trigger, completionHandler: $0) }
                undo.add("removed new automation \(name)") { try await HK.run { home.removeTrigger(trigger, completionHandler: $0) } }
                try await HK.run { trigger.addActionSet(scene!, completionHandler: $0) }
                try await HK.run { trigger.enable(true, completionHandler: $0) }
                return ["ok": true, "automation": name, "id": trigger.uniqueIdentifier.uuidString, "when": describe,
                        "only_if": predicate?.predicateFormat ?? "always", "runs": scene!.name] as [String: Any]
            } catch {
                throw await undo.unwind(after: error)
            }

        case "edit":
            let t = try store.trigger(try a.req("id"), in: home)
            guard let trigger = t as? HMEventTrigger else {
                guard let n = a.str("new_name") else { throw BridgeError.message("\(t.name) is a timer automation; only new_name can change") }
                if !dry { try await HK.run { t.updateName(n, completionHandler: $0) } }
                return [dry ? "would" : "done": "rename automation \(t.name) to \(n)"]
            }
            var changes: [String] = []
            var newEvents: [HMEvent]? = nil
            if a.str("time") != nil {
                newEvents = [try triggerEvent("create_time", a, home).0]; changes.append("trigger: time \(a.str("time")!)")
            } else if a.str("presence") != nil {
                newEvents = [try triggerEvent("create_presence", a, home).0]; changes.append("trigger: presence \(a.str("presence")!)")
            } else if a.str("accessory_id") != nil {
                let te = try triggerEvent("create", a, home); newEvents = [te.0]; changes.append("trigger: \(te.1)")
            }
            let touchesPredicate = a.values["conditions"] != nil || a.values["time_after"] != nil || a.values["time_before"] != nil
            let predicate = touchesPredicate ? try buildPredicate(a, home) : nil
            if touchesPredicate { changes.append("only if: \(predicate?.predicateFormat ?? "always")") }
            let newWeekdays = a.values["weekdays"] != nil
            if newWeekdays { changes.append("weekdays: \(a.ints("weekdays") ?? [])") }
            var newEnd: [HMEvent]? = nil
            if a.bool("clear_duration") == true { newEnd = []; changes.append("auto revert removed") }
            else if a.int("duration_seconds") != nil { newEnd = try durationEvents(a); changes.append("auto revert after \(a.int("duration_seconds")!)s") }
            if let n = a.str("new_name") { changes.append("name: \(n)") }
            guard !changes.isEmpty else { throw BridgeError.message("Nothing to change: pass time, presence, accessory trigger, conditions, time_after/time_before, weekdays, duration_seconds, clear_duration or new_name") }
            if dry { return ["dry_run": true, "automation": t.name, "before": triggerDict(t, detail: false), "changes": changes] as [String: Any] }
            // Copies of what each step replaces, so a later failure can put the earlier steps back.
            func copies(_ events: [HMEvent]) -> [HMEvent] { events.map { ($0 as NSObject).copy() as? HMEvent ?? $0 } }
            let oldEvents = copies(trigger.events), oldEnd = copies(trigger.endEvents)
            let oldPredicate = trigger.predicate, oldRecurrences = trigger.recurrences, oldName = trigger.name
            let undo = Rollback()
            do {
                if let e = newEvents {
                    try await HK.run { trigger.updateEvents(e, completionHandler: $0) }
                    undo.add("restored the trigger") { try await HK.run { trigger.updateEvents(oldEvents, completionHandler: $0) } }
                }
                if touchesPredicate {
                    try await HK.run { trigger.updatePredicate(predicate, completionHandler: $0) }
                    undo.add("restored the conditions") { try await HK.run { trigger.updatePredicate(oldPredicate, completionHandler: $0) } }
                }
                if newWeekdays {
                    try await HK.run { trigger.updateRecurrences(self.weekdayComponents(a), completionHandler: $0) }
                    undo.add("restored the weekdays") { try await HK.run { trigger.updateRecurrences(oldRecurrences, completionHandler: $0) } }
                }
                if let e = newEnd {
                    try await HK.run { trigger.updateEndEvents(e, completionHandler: $0) }
                    undo.add("restored the turn-back") { try await HK.run { trigger.updateEndEvents(oldEnd, completionHandler: $0) } }
                }
                if let n = a.str("new_name") {
                    try await HK.run { trigger.updateName(n, completionHandler: $0) }
                    undo.add("restored the name") { try await HK.run { trigger.updateName(oldName, completionHandler: $0) } }
                }
            } catch {
                throw await undo.unwind(after: error)
            }
            return ["ok": true, "automation": trigger.name, "changes": changes, "after": triggerDict(trigger, detail: false)] as [String: Any]

        default:
            throw BridgeError.message("action must be list, get, create, create_time, create_presence, edit, enable, disable, rename or delete")
        }
    }

    /// The trigger event for create (button or state change), create_time or create_presence.
    func triggerEvent(_ kind: String, _ a: Args, _ home: HMHome) throws -> (HMEvent, String) {
        switch kind {
        case "create_time":
            return try timeEvent(try a.req("time"))
        case "create_presence":
            let spec = try a.req("presence").lowercased()
            let who: HMPresenceEventUserType = (a.str("presence_who") ?? "anyone").lowercased() == "me" ? .currentUser : .homeUsers
            let type: HMPresenceEventType
            switch spec {
            case "first_arrives", "arrive", "first_arrive": type = .firstEntry
            case "last_leaves", "leave", "last_leave": type = .lastExit
            case "any_arrives", "every_arrive": type = .everyEntry
            case "any_leaves", "every_leave": type = .everyExit
            default: throw BridgeError.message("presence must be first_arrives, last_leaves, any_arrives or any_leaves")
            }
            return (HMPresenceEvent(presenceEventType: type, presenceUserType: who), "\(spec) (\(who == .currentUser ? "me" : "anyone"))")
        default:
            let acc = try store.accessory(try a.req("accessory_id"), in: home)
            if let press = a.int("press_type") {
                let (_, c) = try findCharacteristic(acc, HMCharacteristicTypeInputEvent, a)
                try requireNotifying(c, acc.name)
                return (HMCharacteristicEvent<NSCopying>(characteristic: c, triggerValue: NSNumber(value: press)),
                        "\(acc.name) button press \(press)")
            }
            let (_, c) = try findCharacteristic(acc, try a.req("characteristic"), a)
            try requireNotifying(c, acc.name)
            let raw = try a.req("trigger_value")
            let v = try Names.parse(raw, for: c)
            return (HMCharacteristicEvent<NSCopying>(characteristic: c, triggerValue: copying(v)),
                    "\(acc.name) \(Names.name(for: c.characteristicType)) becomes \(raw)")
        }
    }

    func weekdayComponents(_ a: Args) -> [DateComponents]? {
        let days = (a.ints("weekdays") ?? []).filter { (1...7).contains($0) }
        guard !days.isEmpty else { return nil }
        return days.map { var dc = DateComponents(); dc.weekday = $0; return dc }
    }

    func durationEvents(_ a: Args) throws -> [HMEvent]? {
        guard let secs = a.int("duration_seconds") else { return nil }
        guard (1...86400).contains(secs) else { throw BridgeError.message("duration_seconds must be 1 to 86400") }
        return [HMDurationEvent(duration: TimeInterval(secs))]
    }

    /// Conditions ANDed with an optional time window. A window that crosses midnight
    /// (22:00 to 06:00, or sunset to sunrise) is the OR of its two ends.
    func buildPredicate(_ a: Args, _ home: HMHome) throws -> NSPredicate? {
        var parts: [NSPredicate] = []
        for row in a.dicts("conditions") ?? [] {
            let r = Args(row)
            if let p = r.str("presence") {
                let map: [String: (HMPresenceEventType, HMPresenceEventUserType)] = [
                    "anyone_home": (.atHome, .homeUsers), "nobody_home": (.notAtHome, .homeUsers),
                    "me_home": (.atHome, .currentUser), "me_away": (.notAtHome, .currentUser)]
                guard let pair = map[p.lowercased()] else {
                    throw BridgeError.message("presence condition must be anyone_home, nobody_home, me_home or me_away")
                }
                let (type, who) = pair
                parts.append(HMEventTrigger.predicateForEvaluatingTrigger(withPresence:
                    HMPresenceEvent(presenceEventType: type, presenceUserType: who)))
                continue
            }
            var accs = home.accessories
            if let roomKey = r.str("room") { accs = accs.filter { $0.room?.name.caseInsensitiveCompare(roomKey) == .orderedSame } }
            let acc = try store.pick(accs, try r.req("accessory"), kind: "accessory", id: \.uniqueIdentifier, name: \.name)
            let (_, c) = try findCharacteristic(acc, try r.str("property") ?? r.req("characteristic"), r)
            let value = try Names.parse(try r.req("value"), for: c)
            let ops: [String: NSComparisonPredicate.Operator] = ["==": .equalTo, "!=": .notEqualTo, ">": .greaterThan,
                                                                  ">=": .greaterThanOrEqualTo, "<": .lessThan, "<=": .lessThanOrEqualTo]
            guard let op = ops[r.str("op") ?? "=="] else { throw BridgeError.message("op must be ==, !=, >, >=, < or <=") }
            parts.append(HMEventTrigger.predicateForEvaluatingTrigger(c, relatedBy: op, toValue: value))
        }

        let after = (a.strings("time_after") ?? (a.str("time_after").map { [$0] } ?? [])).first
        let before = (a.strings("time_before") ?? (a.str("time_before").map { [$0] } ?? [])).first
        var windowParts: [NSPredicate] = []
        if let after { windowParts.append(try timePredicate(after, after: true)) }
        if let before { windowParts.append(try timePredicate(before, after: false)) }
        if windowParts.count == 2, let after, let before, crossesMidnight(after, before) {
            parts.append(NSCompoundPredicate(orPredicateWithSubpredicates: windowParts))
        } else {
            parts.append(contentsOf: windowParts)
        }

        if parts.isEmpty { return nil }
        return parts.count == 1 ? parts[0] : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    func timePredicate(_ spec: String, after: Bool) throws -> NSPredicate {
        let (event, _) = try timeEvent(spec)
        if let sig = event as? HMSignificantTimeEvent {
            return after ? HMEventTrigger.predicateForEvaluatingTriggerOccurring(afterSignificantEvent: sig)
                         : HMEventTrigger.predicateForEvaluatingTriggerOccurring(beforeSignificantEvent: sig)
        }
        let dc = (event as! HMCalendarEvent).fireDateComponents
        return after ? HMEventTrigger.predicateForEvaluatingTrigger(occurringAfter: dc)
                     : HMEventTrigger.predicateForEvaluatingTrigger(occurringBefore: dc)
    }

    func crossesMidnight(_ after: String, _ before: String) -> Bool {
        let a = after.lowercased(), b = before.lowercased()
        if a.hasPrefix("sunset") && b.hasPrefix("sunrise") { return true }
        func minutes(_ s: String) -> Int? {
            let p = s.split(separator: ":"); guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
            return h * 60 + m
        }
        if let x = minutes(a), let y = minutes(b) { return x > y }
        if a.hasPrefix("sunset"), let y = minutes(b) { return y < 12 * 60 }
        if let x = minutes(a), b.hasPrefix("sunrise") { return x > 12 * 60 }
        return false
    }

    func timeEvent(_ spec: String) throws -> (HMEvent, String) {
        let s = spec.lowercased().replacingOccurrences(of: " ", with: "")
        for (word, sig) in [("sunrise", HMSignificantEvent.sunrise), ("sunset", HMSignificantEvent.sunset)] where s.hasPrefix(word) {
            let rest = s.dropFirst(word.count)
            var offset: DateComponents? = nil
            if !rest.isEmpty {
                guard let mins = Int(rest), abs(mins) <= 1440 else { throw BridgeError.message("Offset must look like sunset-30 or sunrise+15") }
                var dc = DateComponents(); dc.minute = mins; offset = dc
            }
            return (HMSignificantTimeEvent(significantEvent: sig, offset: offset), spec)
        }
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else {
            throw BridgeError.message("time must be HH:MM, sunrise, sunset, or sunset-30 style")
        }
        var dc = DateComponents(); dc.hour = h; dc.minute = m
        return (HMCalendarEvent(fire: dc), String(format: "%02d:%02d", h, m))
    }

    func triggerDict(_ t: HMTrigger, detail: Bool) -> [String: Any] {
        var d: [String: Any] = ["name": t.name, "id": t.uniqueIdentifier.uuidString, "enabled": t.isEnabled,
                                "last_fired": t.lastFireDate as Any, "scenes": t.actionSets.map(\.name)]
        if let e = t as? HMEventTrigger {
            d["kind"] = "event"
            d["events"] = e.events.map(describe)
            if let r = e.recurrences { d["weekdays"] = r.compactMap(\.weekday) }
            if let p = e.predicate { d["only_if"] = p.predicateFormat }
            if !e.endEvents.isEmpty { d["end_events"] = e.endEvents.map(describe) }
        } else if let tt = t as? HMTimerTrigger {
            d["kind"] = "timer"
            d["fire_date"] = tt.fireDate
            if let r = tt.recurrence { d["recurrence"] = "\(r)" }
        }
        if detail {
            d["scene_actions"] = t.actionSets.map { ["scene": $0.name, "actions": $0.actions.compactMap(actionRow)] as [String: Any] }
        }
        return d
    }

    func describe(_ e: HMEvent) -> String {
        if let c = e as? HMCharacteristicEvent<NSCopying> {
            let acc = c.characteristic.service?.accessory?.name ?? "?"
            return "\(acc) \(Names.name(for: c.characteristic.characteristicType)) = \(JSONValue.sanitize(c.triggerValue ?? NSNull()))"
        }
        if let s = e as? HMSignificantTimeEvent {
            let off = s.offset?.minute.map { $0 >= 0 ? "+\($0)" : "\($0)" } ?? ""
            return "\(s.significantEvent.rawValue)\(off)"
        }
        if let c = e as? HMCalendarEvent {
            return String(format: "%02d:%02d", c.fireDateComponents.hour ?? 0, c.fireDateComponents.minute ?? 0)
        }
        if e is HMLocationEvent { return "location" }
        if let p = e as? HMPresenceEvent {
            // .atHome / .notAtHome are aliases of .firstEntry / .lastExit (same raw values), so listing
            // them too makes a duplicate-key literal, which traps at runtime.
            let types: [HMPresenceEventType: String] = [.firstEntry: "first_arrives", .lastExit: "last_leaves",
                                                         .everyEntry: "any_arrives", .everyExit: "any_leaves"]
            return "presence \(types[p.presenceEventType] ?? "?") (\(p.presenceUserType == .currentUser ? "me" : "anyone"))"
        }
        if let d = e as? HMDurationEvent { return "after \(Int(d.duration))s" }
        return "\(type(of: e))"
    }

    // MARK: helpers

    func summary(_ acc: HMAccessory) -> [String: Any] {
        ["name": acc.name, "id": acc.uniqueIdentifier.uuidString, "room": acc.room?.name as Any,
         "category": acc.category.localizedDescription, "reachable": acc.isReachable,
         "state": userServices(acc).map { "\($0.name): \(stateSummary($0))" }]
    }

    func serviceDetail(_ s: HMService) -> [String: Any] {
        var d: [String: Any] = [
            "name": s.name, "id": s.uniqueIdentifier.uuidString, "type": Names.serviceName(for: s.serviceType),
            "type_uuid": s.serviceType, "primary": s.isPrimaryService, "user_interactive": s.isUserInteractive,
            "characteristics": s.characteristics.map(characteristicDetail),
        ]
        if let assoc = s.associatedServiceType { d["displayed_as"] = Names.serviceName(for: assoc) }
        if let idx = s.characteristics.first(where: { $0.characteristicType == Names.serviceLabelIndexType })?.value as? NSNumber {
            d["index"] = idx
        }
        return d
    }

    func characteristicDetail(_ c: HMCharacteristic) -> [String: Any] {
        var d: [String: Any] = [
            "name": Names.name(for: c.characteristicType), "type": c.characteristicType,
            "description": c.localizedDescription, "value": JSONValue.sanitize(c.value ?? NSNull()),
            "readable": c.properties.contains(HMCharacteristicPropertyReadable),
            "writable": c.properties.contains(HMCharacteristicPropertyWritable),
        ]
        if let m = c.metadata {
            if let f = m.format { d["format"] = f }
            if let v = m.minimumValue { d["min"] = v }
            if let v = m.maximumValue { d["max"] = v }
            if let v = m.stepValue { d["step"] = v }
            if let v = m.units { d["units"] = v }
            if let v = m.validValues, !v.isEmpty { d["valid_values"] = v }
            if let v = m.manufacturerDescription { d["manufacturer_description"] = v }
        }
        return d
    }

    func userServices(_ acc: HMAccessory) -> [HMService] {
        acc.services.filter { $0.serviceType != HMServiceTypeAccessoryInformation && $0.isUserInteractive }
    }

    func isWritable(_ c: HMCharacteristic) -> Bool {
        c.properties.contains(HMCharacteristicPropertyWritable) && c.characteristicType != HMCharacteristicTypeIdentify
            && c.characteristicType != HMCharacteristicTypeName
    }

    func stateSummary(_ s: HMService) -> String {
        let interesting = s.characteristics.filter {
            $0.properties.contains(HMCharacteristicPropertyReadable) && $0.characteristicType != HMCharacteristicTypeName
                && Names.characteristics[$0.characteristicType] != nil
        }
        return interesting.prefix(4).map { "\(Names.name(for: $0.characteristicType))=\(JSONValue.sanitize($0.value ?? "?"))" }
            .joined(separator: ", ")
    }

    func sceneType(_ s: HMActionSet) -> String {
        switch s.actionSetType {
        case HMActionSetTypeWakeUp: return "wake_up"
        case HMActionSetTypeSleep: return "sleep"
        case HMActionSetTypeHomeDeparture: return "leave_home"
        case HMActionSetTypeHomeArrival: return "arrive_home"
        case HMActionSetTypeTriggerOwned: return "automation_owned"
        default: return "user"
        }
    }

    func actionRow(_ action: HMAction) -> [String: Any]? {
        guard let w = action as? HMCharacteristicWriteAction<NSCopying> else { return nil }
        let c = w.characteristic
        return ["accessory": c.service?.accessory?.name ?? "?", "accessory_id": c.service?.accessory?.uniqueIdentifier.uuidString ?? "",
                "service": c.service?.name ?? "?", "property": Names.name(for: c.characteristicType),
                "value": JSONValue.sanitize(w.targetValue)]
    }

    func pickService(_ acc: HMAccessory, _ a: Args, prefer: [String] = []) throws -> HMService {
        var list = acc.services
        if let id = a.str("service_id") ?? a.str("service_name").flatMap({ UUID(uuidString: $0) != nil ? $0 : nil }) {
            list = list.filter { $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(id) == .orderedSame }
        } else if let n = a.str("service_name") {
            list = list.filter { $0.name.caseInsensitiveCompare(n) == .orderedSame }
        }
        if let idx = a.int("service_index") {
            list = list.filter { s in
                (s.characteristics.first { $0.characteristicType == Names.serviceLabelIndexType }?.value as? NSNumber)?.intValue == idx
            }
        }
        if !prefer.isEmpty, !a.hasServiceSelector { list = list.filter { prefer.contains($0.serviceType) } }
        if !a.hasServiceSelector, list.count > 1 { list = list.filter { $0.serviceType != HMServiceTypeAccessoryInformation } }
        guard let first = list.first else { throw BridgeError.message("No service on \(acc.name) matches") }
        guard list.count == 1 else {
            let opts = list.map { "\($0.name) = \($0.uniqueIdentifier.uuidString)" }.joined(separator: "; ")
            throw BridgeError.message("Several services on \(acc.name) match; pass service_id: \(opts)")
        }
        return first
    }

    /// Finds a characteristic by friendly name or type UUID, narrowed by service selectors.
    func findCharacteristic(_ acc: HMAccessory, _ key: String, _ a: Args) throws -> (HMService, HMCharacteristic) {
        let type = Names.characteristicType(for: key)
        var services = acc.services
        if a.hasServiceSelector { services = [try pickService(acc, a)] }
        let hits = services.flatMap { s in s.characteristics.filter { $0.characteristicType == type }.map { (s, $0) } }
        guard let first = hits.first else {
            throw BridgeError.message("\(acc.name) has no \(key). Use homekit_accessories get to list its characteristics.")
        }
        let distinct = Set(hits.map { $0.0.uniqueIdentifier })
        guard distinct.count == 1 else {
            let opts = hits.map { "\($0.0.name) = \($0.0.uniqueIdentifier.uuidString)" }.joined(separator: "; ")
            throw BridgeError.message("\(key) is on several services of \(acc.name); pass service_id or service_index: \(opts)")
        }
        return first
    }

    func copying(_ v: Any) -> NSCopying {
        if let n = v as? NSNumber { return n }
        if let s = v as? String { return s as NSString }
        if let d = v as? Data { return d as NSData }
        return "\(v)" as NSString
    }
}

// MARK: - arguments

/// Locks, garage doors and security systems: writes to them (directly, or through a scene or an
/// automation that runs one) need confirm=true, so a client cannot open a door by accident.
@MainActor
enum Sensitive {
    static let types: Set<String> = Set([
        HMCharacteristicTypeTargetLockMechanismState,
        HMCharacteristicTypeTargetDoorState,
        HMCharacteristicTypeTargetSecuritySystemState,
    ].map { $0.uppercased() })

    static let note = "Changes a lock, garage door or security system: the real call needs confirm=true."

    /// "Front Door / Lock Mechanism" for each sensitive characteristic, without duplicates.
    static func names(_ chars: [HMCharacteristic]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for c in chars where types.contains(c.characteristicType.uppercased()) {
            let label = [c.service?.accessory?.name, c.service?.name].compactMap { $0 }.joined(separator: " / ")
            if seen.insert(label).inserted { out.append(label) }
        }
        return out
    }

    static func names(sets: [HMActionSet]) -> [String] {
        names(sets.flatMap { $0.actions.compactMap { ($0 as? HMCharacteristicWriteAction<NSCopying>)?.characteristic } })
    }

    static func require(_ found: [String], _ a: Args) throws {
        guard !found.isEmpty, a.values["confirm"] as? Bool != true, (a.values["confirm"] as? String)?.lowercased() != "true" else { return }
        throw BridgeError.message("This changes a lock, garage door or security system (\(found.joined(separator: ", "))). Confirm with the person, then repeat the call with confirm=true.")
    }

    /// Adds needs_confirm to a dry-run result when it touches something sensitive.
    static func flag(_ d: [String: Any], _ found: [String]) -> [String: Any] {
        guard !found.isEmpty else { return d }
        var d = d
        d["needs_confirm"] = note
        d["sensitive"] = found
        return d
    }
}

struct Args {
    var values: [String: Any]
    init(_ v: [String: Any]) { values = v.filter { !($0.value is NSNull) } }

    func str(_ k: String) -> String? {
        if let s = values[k] as? String { return s.isEmpty ? nil : s }
        if let n = values[k] as? NSNumber { return n.stringValue }
        return nil
    }
    func req(_ k: String) throws -> String {
        guard let s = str(k) else { throw BridgeError.message("\(k) is required") }
        return s
    }
    func bool(_ k: String) -> Bool? {
        if let b = values[k] as? Bool { return b }
        if let s = values[k] as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
        return nil
    }
    func int(_ k: String) -> Int? {
        if let n = values[k] as? NSNumber { return n.intValue }
        if let s = values[k] as? String { return Int(s) }
        return nil
    }
    func ints(_ k: String) -> [Int]? { (values[k] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue ?? Int("\($0)") } }
    func strings(_ k: String) -> [String]? { (values[k] as? [Any])?.compactMap { $0 as? String } }
    func dicts(_ k: String) -> [[String: Any]]? { values[k] as? [[String: Any]] }

    var hasServiceSelector: Bool { str("service_id") != nil || str("service_name") != nil || int("service_index") != nil }

    func isWrite(tool: String) -> Bool {
        let action = str("action")
        switch tool {
        case "homekit_accessories": return action == "control" && bool("dry_run") != true
        case "homekit_scenes": return action == "trigger"
        case "homekit_manage": return action != "list_groups" && bool("dry_run") != true
        case "homekit_scene_edit": return bool("dry_run") != true
        case "homekit_automations": return !["list", "get", nil].contains(action) && bool("dry_run") != true
        default: return false
        }
    }
}

enum Audit {
    static func write(tool: String, args: [String: Any], ok: Bool, error: String?) {
        let dir = TokenFile.directory.replacingOccurrences(of: "/.config/homekit-bridge", with: "/Library/Logs/homekit-bridge")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var entry: [String: Any] = ["t": ISO8601DateFormatter().string(from: Date()), "tool": tool, "ok": ok]
        for k in ["action", "accessory_id", "id", "characteristic", "value", "new_name", "name", "scene", "scene_id",
                  "room", "zone", "group", "display_as", "time", "home_id"] {
            if let v = args[k] { entry[k] = JSONValue.sanitize(v) }
        }
        if let error { entry["error"] = String(error.prefix(300)) }
        guard let data = try? JSONSerialization.data(withJSONObject: entry), var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let path = dir + "/actions.jsonl"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
        }
    }
}

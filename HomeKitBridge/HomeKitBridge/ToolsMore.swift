import Foundation
import HomeKit
import CoreLocation
import UIKit

/// Public-API coverage beyond the original tools: home-level settings, users, hub state,
/// accessory identify/unblock/setup/discovery, single and batch characteristic reads and
/// writes, notifications, linked services and profiles, cameras, granular scene actions,
/// built-in scenes, multi-event automations (characteristic value, any change, threshold
/// range, time, sun, presence, location; end events; any/all/not conditions; execute once;
/// several scenes) and timer automations.
///
/// Hooked in from Tools.swift by `default: result = try await callMore(name: name, a: a, raw: args)`.
/// Uses ToolRouter helpers from Tools.swift, which must not be `private` (see PATCH.md).
extension ToolRouter {

    /// HMHome.supportsAddingNetworkRouter is unavailable in Mac Catalyst (null there).
    func networkRouterSupport(_ h: HMHome) -> Any {
        #if targetEnvironment(macCatalyst)
        return NSNull()
        #else
        return h.supportsAddingNetworkRouter
        #endif
    }

    func callMore(name: String, a: Args, raw: [String: Any]) async throws -> Any {
        let isWrite = moreIsWrite(name, a)
        do {
            let r: Any
            switch name {
            case "homekit_home": r = try await homeTool(a)
            case "homekit_devices": r = try await devicesTool(a)
            case "homekit_cameras": r = try await camerasTool(a)
            case "homekit_scene_actions": r = try await sceneActionsTool(a)
            case "homekit_triggers": r = try await triggersTool(a)
            case "private_probe": r = try await PrivateTools(store: store).probe(a)
            case "private_homed_db": r = try PrivateTools(store: store).homedDB(a)
            default: throw BridgeError.message("Unknown tool: \(name)")
            }
            if isWrite { Audit.write(tool: name, args: raw, ok: true, error: nil) }
            return r
        } catch {
            if isWrite { Audit.write(tool: name, args: raw, ok: false, error: "\(error)") }
            throw error
        }
    }

    private func moreIsWrite(_ tool: String, _ a: Args) -> Bool {
        if a.bool("dry_run") == true { return false }
        let act = a.str("action") ?? ""
        let reads: Set<String> = ["", "info", "users", "discover", "read", "linked_services", "profiles", "list", "settings",
                                  "snapshot", "snapshot_info", "get", "builtin", "describe", "classes", "tables", "schema",
                                  "query", "decode", "automation_actions"]
        if tool == "private_homed_db" { return false }
        // private_probe call is a dry run unless dry_run is explicitly false.
        if tool == "private_probe" && act == "call" { return a.bool("dry_run") == false }
        return !reads.contains(act)
    }

    private func doneDict(_ dry: Bool, _ what: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var d = extra
        d[dry ? "would" : "done"] = what
        if dry { d["dry_run"] = true }
        return d
    }

    // MARK: - homekit_home

    private func homeTool(_ a: Args) async throws -> Any {
        let dry = a.bool("dry_run") ?? false
        let action = a.str("action") ?? "info"
        switch action {
        case "info":
            return store.manager.homes.map { h -> [String: Any] in
                var d: [String: Any] = ["name": h.name, "id": h.uniqueIdentifier.uuidString, "primary": h.isPrimary,
                                        "hub_state": hubState(h.homeHubState),
                                        "supports_network_router": networkRouterSupport(h),
                                        "accessories": h.accessories.count, "rooms": h.rooms.count, "zones": h.zones.count,
                                        "scenes": h.actionSets.count, "automations": h.triggers.count,
                                        "groups": h.serviceGroups.count]
                let u = h.currentUser
                d["current_user"] = ["name": u.name, "id": u.uniqueIdentifier.uuidString,
                                     "administrator": h.homeAccessControl(for: u).isAdministrator] as [String: Any]
                return d
            }
        case "users":
            let h = try store.home(a.str("home_id"))
            let u = h.currentUser
            // Apple's public API exposes only the current user; the full list and invitations
            // live behind manage_users, which opens Apple's own sheet on the Mac.
            return ["home": h.name, "current_user": u.name, "administrator": h.homeAccessControl(for: u).isAdministrator,
                    "note": "Other users are only visible in Apple's Manage Users sheet (action manage_users)."] as [String: Any]
        case "manage_users":
            let h = try store.home(a.str("home_id"))
            if dry { return doneDict(true, "open Apple's Manage Users sheet for \(h.name) on the Mac") }
            try await HK.run(timeout: nil) { h.manageUsers(completionHandler: $0) }
            return ["ok": true, "note": "Apple's sheet was shown on the Mac; changes are made there by a person."] as [String: Any]
        case "rename_home":
            let h = try store.home(a.str("home_id"))
            let n = try a.req("new_name")
            if !dry { try await HK.run { h.updateName(n, completionHandler: $0) } }
            return doneDict(dry, "rename home \(h.name) to \(n)")
        case "add_home":
            let n = try a.req("name")
            if !dry { _ = try await HK.make { store.manager.addHome(withName: n, completionHandler: $0) } as HMHome }
            return doneDict(dry, "create home \(n)")
        case "remove_home":
            let h = try store.home(try a.req("home_id"))
            guard dry || a.bool("confirm") == true else {
                throw BridgeError.message("remove_home deletes \(h.name) with all its rooms, scenes and automations and unpairs its accessories. Pass confirm=true (and preview with dry_run first).")
            }
            if !dry { try await HK.run { store.manager.removeHome(h, completionHandler: $0) } }
            return doneDict(dry, "remove home \(h.name)", ["accessories": h.accessories.count, "automations": h.triggers.count])
        case "set_primary":
            let h = try store.home(try a.req("home_id"))
            // Deprecated by Apple in iOS 16.1 ("No longer supported"); kept because it still compiles. It may be a no-op.
            if !dry { try await HK.run { store.manager.updatePrimaryHome(h, completionHandler: $0) } }
            return doneDict(dry, "make \(h.name) the primary home", ["note": "Apple deprecated this call; check the Home app."])
        case "add_accessory":
            let h = try store.home(a.str("home_id"))
            if dry { return doneDict(true, "open Apple's accessory setup on the Mac for \(h.name)") }
            return try await accessorySetup(h, a)
        case "discover":
            #if targetEnvironment(macCatalyst)
            throw BridgeError.message("discover is not available on this Mac (HMAccessoryBrowser is unavailable in Mac Catalyst)")
            #else
            let secs = min(max(a.int("seconds") ?? 10, 3), 60)
            let found = try await AccessoryDiscovery.scan(seconds: secs)
            return ["seconds": secs, "found": found] as [String: Any]
            #endif
        default:
            throw BridgeError.message("action must be info, users, manage_users, rename_home, add_home, remove_home, set_primary, add_accessory or discover")
        }
    }

    private func hubState(_ s: HMHomeHubState) -> String {
        switch s {
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .notAvailable: return "not_available"
        @unknown default: return "unknown"
        }
    }

    private func accessorySetup(_ h: HMHome, _ a: Args) async throws -> Any {
        // Apple made HMAccessorySetupManager available on Mac Catalyst in macOS 27. If Xcode reports
        // it unavailable for this SDK, delete this function body down to the throw (see PATCH.md).
        if #available(macCatalyst 27.0, iOS 15.4, *) {
            let request = HMAccessorySetupRequest()
            request.homeUniqueIdentifier = h.uniqueIdentifier
            if let s = a.str("setup_url"), let url = URL(string: s) {
                request.payload = HMAccessorySetupPayload(url: url)
            }
            let result = try await HMAccessorySetupManager().performAccessorySetup(using: request)
            return ["ok": true, "home": h.name, "added": result.accessoryUniqueIdentifiers.map(\.uuidString)] as [String: Any]
        }
        throw BridgeError.message("Accessory setup from this Mac needs macOS 27 or later; add it in the Home app on iPhone.")
    }

    // MARK: - homekit_devices

    private func devicesTool(_ a: Args) async throws -> Any {
        let home = try store.home(a.str("home_id"))
        let dry = a.bool("dry_run") ?? false
        let action = try a.req("action")
        switch action {
        case "identify":
            let acc = try store.accessory(try a.req("accessory_id"), in: home)
            guard acc.supportsIdentify else { throw BridgeError.message("\(acc.name) does not support identify") }
            if !dry { try await HK.run { acc.identify(completionHandler: $0) } }
            return doneDict(dry, "identify \(acc.name) (it blinks or beeps)")
        case "unblock":
            let acc = try store.accessory(try a.req("accessory_id"), in: home)
            guard acc.isBlocked else { return ["note": "\(acc.name) is not blocked"] }
            if !dry { try await HK.run { home.unblockAccessory(acc, completionHandler: $0) } }
            return doneDict(dry, "unblock \(acc.name)")
        case "read":
            let acc = try store.accessory(try a.req("accessory_id"), in: home)
            let (s, c) = try findCharacteristic(acc, try a.req("characteristic"), a)
            guard c.properties.contains(HMCharacteristicPropertyReadable) else {
                throw BridgeError.message("\(Names.name(for: c.characteristicType)) on \(acc.name) is not readable")
            }
            try await HK.run { c.readValue(completionHandler: $0) }
            var d = characteristicDetail(c)
            d["accessory"] = acc.name; d["service"] = s.name
            return d
        case "write_many":
            guard let rows = a.dicts("writes"), !rows.isEmpty else {
                throw BridgeError.message("writes is required: [{accessory, property, value, room?, service_*?}]")
            }
            // Resolve and validate every row first, so a bad row stops the batch before anything is written.
            var planned: [(c: HMCharacteristic?, v: Any?, item: [String: Any])] = []
            for row in rows {
                let r = Args(row)
                var accs = home.accessories
                if let roomKey = r.str("room") { accs = accs.filter { $0.room?.name.caseInsensitiveCompare(roomKey) == .orderedSame } }
                let acc = try store.pick(accs, try r.req("accessory"), kind: "accessory", id: \.uniqueIdentifier, name: \.name)
                let (s, c) = try findCharacteristic(acc, try r.str("property") ?? r.req("characteristic"), r)
                guard c.properties.contains(HMCharacteristicPropertyWritable) else {
                    planned.append((nil, nil, ["accessory": acc.name, "ok": false, "error": "not writable"])); continue
                }
                let v = try Names.parse(try r.req("value"), for: c)
                planned.append((c, v, ["accessory": acc.name, "service": s.name,
                                       "property": Names.name(for: c.characteristicType),
                                       "previous": JSONValue.sanitize(c.value ?? NSNull()), "value": JSONValue.sanitize(v)]))
            }
            let sensitive = Sensitive.names(planned.compactMap(\.c))
            if !dry { try Sensitive.require(sensitive, a) }
            var out: [[String: Any]] = []
            for (cOpt, vOpt, plannedItem) in planned {
                var item = plannedItem
                guard let c = cOpt, let v = vOpt else { out.append(item); continue }
                if dry { item["dry_run"] = true; out.append(item); continue }
                do {
                    try await HK.run { c.writeValue(v, completionHandler: $0) }
                    item["ok"] = true
                    if (a.bool("verify") ?? true) && c.properties.contains(HMCharacteristicPropertyReadable) {
                        try? await HK.run { c.readValue(completionHandler: $0) }
                        item["verified"] = Names.same(c.value, v)
                        item["reads"] = JSONValue.sanitize(c.value ?? NSNull())
                    }
                    // HomeKit does not report this app's own writes back to it; record them for the history.
                    if let s = c.service, let acc = s.accessory { History.shared.change(acc, s, c, byBridge: true) }
                } catch {
                    item["ok"] = false; item["error"] = "\(error.localizedDescription)"
                }
                out.append(item)
            }
            return ["dry_run": dry, "writes": out] as [String: Any]
        case "notify":
            let acc = try store.accessory(try a.req("accessory_id"), in: home)
            let on = a.bool("enable") ?? true
            var targets: [HMCharacteristic] = []
            if let key = a.str("characteristic") {
                let c = try findCharacteristic(acc, key, a).1
                guard c.properties.contains(HMCharacteristicPropertySupportsEventNotification) else {
                    throw BridgeError.message("\(Names.name(for: c.characteristicType)) on \(acc.name) does not send change notifications")
                }
                targets = [c]
            } else {
                targets = acc.services.flatMap(\.characteristics)
                    .filter { $0.properties.contains(HMCharacteristicPropertySupportsEventNotification) }
            }
            if !dry {
                let undo = Rollback()
                do {
                    for c in targets {
                        let was = c.isNotificationEnabled
                        try await HK.run { c.enableNotification(on, completionHandler: $0) }
                        undo.add("restored notifications on \(Names.name(for: c.characteristicType))") {
                            try await HK.run { c.enableNotification(was, completionHandler: $0) }
                        }
                    }
                } catch {
                    throw await undo.unwind(after: error)
                }
            }
            return doneDict(dry, "\(on ? "enable" : "disable") change notifications on \(acc.name)",
                            ["characteristics": targets.map { Names.name(for: $0.characteristicType) },
                             "note": "Changes then appear in homekit_events as characteristic_change while the bridge runs."])
        case "linked_services":
            let acc = try store.accessory(try a.req("accessory_id"), in: home)
            return acc.services.map { s -> [String: Any] in
                var d: [String: Any] = ["service": s.name, "id": s.uniqueIdentifier.uuidString,
                                        "type": Names.serviceName(for: s.serviceType), "primary": s.isPrimaryService,
                                        "user_interactive": s.isUserInteractive,
                                        "linked": (s.linkedServices ?? []).map { ["name": $0.name, "id": $0.uniqueIdentifier.uuidString,
                                                                                  "type": Names.serviceName(for: $0.serviceType)] }]
                if #available(iOS 16.1, macCatalyst 18.0, *) { d["matter_endpoint"] = s.matterEndpointID as Any }
                return d
            }
        case "profiles":
            let acc = try store.accessory(try a.req("accessory_id"), in: home)
            var d: [String: Any] = ["accessory": acc.name, "bridged": acc.isBridged, "blocked": acc.isBlocked,
                                    "supports_identify": acc.supportsIdentify,
                                    "bridged_accessories": (acc.uniqueIdentifiersForBridgedAccessories ?? []).map(\.uuidString),
                                    "manufacturer": acc.manufacturer as Any, "model": acc.model as Any,
                                    "firmware": acc.firmwareVersion as Any, "category": acc.category.localizedDescription,
                                    "category_type": acc.category.categoryType]
            if #available(iOS 16.1, macCatalyst 16.1, *) { d["matter_node_id"] = acc.matterNodeID as Any }
            d["profiles"] = acc.profiles.map { p -> [String: Any] in
                var pd: [String: Any] = ["kind": "\(type(of: p))", "id": p.uniqueIdentifier.uuidString,
                                         "services": p.services.map(\.name)]
                if let n = p as? HMNetworkConfigurationProfile { pd["network_access_restricted"] = n.isNetworkAccessRestricted }
                if p is HMCameraProfile { pd["camera"] = true }
                return pd
            }
            return d
        default:
            throw BridgeError.message("action must be identify, unblock, read, write_many, notify, linked_services or profiles")
        }
    }

    // MARK: - homekit_cameras

    private func camerasTool(_ a: Args) async throws -> Any {
        let home = try store.home(a.str("home_id"))
        let dry = a.bool("dry_run") ?? false
        let action = a.str("action") ?? "list"
        if action == "list" {
            return home.accessories.filter { !($0.cameraProfiles ?? []).isEmpty }.map { acc in
                ["name": acc.name, "id": acc.uniqueIdentifier.uuidString, "room": acc.room?.name as Any,
                 "reachable": acc.isReachable, "profiles": (acc.cameraProfiles ?? []).count] as [String: Any]
            }
        }
        let acc = try store.accessory(try a.req("accessory_id"), in: home)
        guard let cam = acc.cameraProfiles?.first else { throw BridgeError.message("\(acc.name) has no camera") }
        let controls = cameraControls(cam)
        switch action {
        case "settings":
            var out: [String: Any] = [:]
            for (k, c) in controls {
                if c.properties.contains(HMCharacteristicPropertyReadable) { try? await HK.run { c.readValue(completionHandler: $0) } }
                out[k] = characteristicDetail(c)
            }
            if let snap = cam.snapshotControl?.mostRecentSnapshot { out["last_snapshot"] = snap.captureDate }
            return ["camera": acc.name, "settings": out,
                    "not_public": "Recording modes (stream/record/off per home or away), activity zones and clip history are Home-app only."] as [String: Any]
        case "set":
            let key = try a.req("setting")
            guard let c = controls[key] else {
                throw BridgeError.message("setting must be one of: \(controls.keys.sorted().joined(separator: ", "))")
            }
            guard c.properties.contains(HMCharacteristicPropertyWritable) else { throw BridgeError.message("\(key) is read-only on \(acc.name)") }
            let v = try Names.parse(try a.req("value"), for: c)
            let before = JSONValue.sanitize(c.value ?? NSNull())
            if !dry {
                try await HK.run { c.writeValue(v, completionHandler: $0) }
                if let s = c.service { History.shared.change(acc, s, c, byBridge: true) }
            }
            return doneDict(dry, "set \(acc.name) \(key) to \(JSONValue.sanitize(v))", ["previous": before])
        case "snapshot":
            guard let sc = cam.snapshotControl else { throw BridgeError.message("\(acc.name) offers no snapshots") }
            let snap = try await CameraSnapshot.take(sc)
            var d: [String: Any] = ["camera": acc.name, "captured": snap.captureDate]
            if a.bool("image") == true {
                // Experimental: Apple only lets a snapshot be drawn in HMCameraView, so this renders that view
                // offscreen. It can come back blank; captured is always correct.
                if let jpeg = CameraSnapshot.render(snap) { d["image_jpeg_base64"] = jpeg.base64EncodedString(); d["bytes"] = jpeg.count }
                else { d["image_note"] = "could not render" }
            }
            return d
        default:
            throw BridgeError.message("action must be list, settings, set or snapshot")
        }
    }

    private func cameraControls(_ cam: HMCameraProfile) -> [String: HMCharacteristic] {
        var m: [String: HMCharacteristic] = [:]
        if let s = cam.settingsControl {
            let pairs: [(String, HMCharacteristic?)] = [
                ("night_vision", s.nightVision), ("image_rotation", s.imageRotation), ("image_mirroring", s.imageMirroring),
                ("optical_zoom", s.opticalZoom), ("digital_zoom", s.digitalZoom),
                ("current_horizontal_tilt", s.currentHorizontalTilt), ("target_horizontal_tilt", s.targetHorizontalTilt),
                ("current_vertical_tilt", s.currentVerticalTilt), ("target_vertical_tilt", s.targetVerticalTilt)]
            for (k, c) in pairs { if let c { m[k] = c } }
        }
        if let sp = cam.speakerControl { if let c = sp.mute { m["speaker_mute"] = c }; if let c = sp.volume { m["speaker_volume"] = c } }
        if let mic = cam.microphoneControl { if let c = mic.mute { m["microphone_mute"] = c }; if let c = mic.volume { m["microphone_volume"] = c } }
        return m
    }

    // MARK: - homekit_scene_actions

    private func sceneActionsTool(_ a: Args) async throws -> Any {
        let home = try store.home(a.str("home_id"))
        let dry = a.bool("dry_run") ?? false
        switch try a.req("action") {
        case "builtin":
            let types: [(String, String)] = [("wake_up", HMActionSetTypeWakeUp), ("sleep", HMActionSetTypeSleep),
                                             ("leave_home", HMActionSetTypeHomeDeparture), ("arrive_home", HMActionSetTypeHomeArrival)]
            return types.compactMap { (k, t) -> [String: Any]? in
                guard let s = home.builtinActionSet(ofType: t) else { return nil }
                return ["type": k, "name": s.name, "id": s.uniqueIdentifier.uuidString, "actions": s.actions.compactMap(actionRow)]
            }
        case "add":
            let set = try store.scene(try a.req("scene"), in: home)
            let writes = try writeActions(a.dicts("actions"), home)
            if !dry {
                try Sensitive.require(Sensitive.names(writes.map(\.0.characteristic)), a)
                let undo = Rollback()
                do {
                    for (w, _) in writes {
                        try await HK.run { set.addAction(w, completionHandler: $0) }
                        undo.add("removed a new action") { try await HK.run { set.removeAction(w, completionHandler: $0) } }
                    }
                } catch {
                    throw await undo.unwind(after: error)
                }
            }
            return doneDict(dry, "add \(writes.count) action(s) to \(set.name)", ["actions": writes.map(\.1)])
        case "remove":
            let set = try store.scene(try a.req("scene"), in: home)
            let accKey = try a.req("accessory")
            let prop = a.str("property")
            let hits = set.actions.compactMap { $0 as? HMCharacteristicWriteAction<NSCopying> }.filter { w in
                let acc = w.characteristic.service?.accessory
                let accOK = acc?.name.caseInsensitiveCompare(accKey) == .orderedSame
                    || acc?.uniqueIdentifier.uuidString.caseInsensitiveCompare(accKey) == .orderedSame
                let propOK = prop == nil || Names.name(for: w.characteristic.characteristicType) == prop
                    || w.characteristic.characteristicType.caseInsensitiveCompare(prop!) == .orderedSame
                return accOK && propOK
            }
            guard !hits.isEmpty else { throw BridgeError.message("No action in \(set.name) matches \(accKey)\(prop.map { " / \($0)" } ?? "")") }
            if !dry {
                let undo = Rollback()
                do {
                    for w in hits {
                        let c = w.characteristic, v = w.targetValue
                        try await HK.run { set.removeAction(w, completionHandler: $0) }
                        undo.add("restored a removed action") {
                            try await HK.run { set.addAction(HMCharacteristicWriteAction<NSCopying>(characteristic: c, targetValue: v), completionHandler: $0) }
                        }
                    }
                } catch {
                    throw await undo.unwind(after: error)
                }
            }
            return doneDict(dry, "remove \(hits.count) action(s) from \(set.name)", ["actions": hits.compactMap { actionRow($0) }])
        default:
            throw BridgeError.message("action must be builtin, add or remove")
        }
    }

    // MARK: - homekit_triggers (full HMEventTrigger / HMTimerTrigger)

    private func triggersTool(_ a: Args) async throws -> Any {
        let home = try store.home(a.str("home_id"))
        let dry = a.bool("dry_run") ?? false
        switch try a.req("action") {
        case "get":
            let t = try store.trigger(try a.req("id"), in: home)
            var d = triggerDict(t, detail: true)
            if let e = t as? HMEventTrigger {
                d["execute_once"] = e.executeOnce
                d["activation_state"] = activationState(e.triggerActivationState)
                d["events_detail"] = e.events.map(eventDetail)
                d["end_events_detail"] = e.endEvents.map(eventDetail)
            }
            return d
        case "create_event":
            let name = try a.req("name")
            let events = try eventList(a.dicts("events"), home, allowDuration: false)
            guard !events.isEmpty else { throw BridgeError.message("events is required (any one of them fires the automation)") }
            let end = try eventList(a.dicts("end_events"), home, allowDuration: true)
            let predicate = try conditionPredicate(a, home)
            let recurrences = weekdayComponents(a)
            try requireNewAutomationName(name, home)
            let scenes = try scenesFor(a, home, name: name, dry: dry)
            if dry {
                return Sensitive.flag(["dry_run": true, "would": "create automation \(name)", "when_any": events.map(describe),
                        "end_events": end.map(describe), "only_if": predicate?.predicateFormat ?? "always",
                        "weekdays": a.ints("weekdays") ?? [], "execute_once": a.bool("execute_once") ?? false,
                        "runs": scenes.names], scenes.sensitive)
            }
            try Sensitive.require(scenes.sensitive, a)
            let undo = Rollback()
            let trigger = HMEventTrigger(name: name, events: events, end: end.isEmpty ? nil : end,
                                         recurrences: recurrences, predicate: predicate)
            do {
                let sets = try await scenes.resolve(undo)
                try await HK.run { home.addTrigger(trigger, completionHandler: $0) }
                undo.add("removed new automation \(name)") { try await HK.run { home.removeTrigger(trigger, completionHandler: $0) } }
                for s in sets { try await HK.run { trigger.addActionSet(s, completionHandler: $0) } }
                if a.bool("execute_once") == true { try await HK.run { trigger.updateExecuteOnce(true, completionHandler: $0) } }
                if a.bool("enabled") ?? true { try await HK.run { trigger.enable(true, completionHandler: $0) } }
            } catch {
                throw await undo.unwind(after: error)
            }
            return ["ok": true, "automation": name, "id": trigger.uniqueIdentifier.uuidString,
                    "activation_state": activationState(trigger.triggerActivationState),
                    "only_if": predicate?.predicateFormat ?? "always", "runs": trigger.actionSets.map(\.name)] as [String: Any]
        case "create_timer":
            let name = try a.req("name")
            let fire = try fireDate(try a.req("fire_date"))
            let rec = try recurrence(a)
            try requireNewAutomationName(name, home)
            let scenes = try scenesFor(a, home, name: name, dry: dry)
            if dry {
                return Sensitive.flag(["dry_run": true, "would": "create timer automation \(name)", "fire_date": fire,
                        "recurrence": a.values["recurrence"] as Any, "runs": scenes.names], scenes.sensitive)
            }
            try Sensitive.require(scenes.sensitive, a)
            let trigger = HMTimerTrigger(name: name, fireDate: fire, recurrence: rec)
            let undo = Rollback()
            do {
                let sets = try await scenes.resolve(undo)
                try await HK.run { home.addTrigger(trigger, completionHandler: $0) }
                undo.add("removed new automation \(name)") { try await HK.run { home.removeTrigger(trigger, completionHandler: $0) } }
                for s in sets { try await HK.run { trigger.addActionSet(s, completionHandler: $0) } }
                if a.bool("enabled") ?? true { try await HK.run { trigger.enable(true, completionHandler: $0) } }
            } catch {
                throw await undo.unwind(after: error)
            }
            return ["ok": true, "automation": name, "id": trigger.uniqueIdentifier.uuidString, "fire_date": trigger.fireDate] as [String: Any]
        case "update":
            let t = try store.trigger(try a.req("id"), in: home)
            var changes: [String] = []
            if let e = t as? HMEventTrigger {
                var newEvents: [HMEvent]? = nil, newEnd: [HMEvent]? = nil
                if a.values["events"] != nil { newEvents = try eventList(a.dicts("events"), home, allowDuration: false); changes.append("events") }
                if a.values["end_events"] != nil { newEnd = try eventList(a.dicts("end_events"), home, allowDuration: true); changes.append("end_events") }
                let touchPred = a.values["conditions"] != nil || a.values["time_after"] != nil || a.values["time_before"] != nil
                let pred = touchPred ? try conditionPredicate(a, home) : nil
                if touchPred { changes.append("only_if: \(pred?.predicateFormat ?? "always")") }
                if a.values["weekdays"] != nil { changes.append("weekdays") }
                if a.values["execute_once"] != nil { changes.append("execute_once: \(a.bool("execute_once") ?? false)") }
                let addScenes = try (a.strings("add_scenes") ?? []).map { try store.scene($0, in: home) }
                let removeScenes = try (a.strings("remove_scenes") ?? []).map { try store.scene($0, in: home) }
                if !addScenes.isEmpty { changes.append("add scenes \(addScenes.map(\.name))") }
                if !removeScenes.isEmpty { changes.append("remove scenes \(removeScenes.map(\.name))") }
                if let n = a.str("new_name") { changes.append("name: \(n)") }
                guard !changes.isEmpty else { throw BridgeError.message("Nothing to change") }
                let sensitive = Sensitive.names(sets: addScenes)
                if dry { return Sensitive.flag(["dry_run": true, "automation": t.name, "changes": changes], sensitive) }
                try Sensitive.require(sensitive, a)
                func copies(_ evs: [HMEvent]) -> [HMEvent] { evs.map { ($0 as NSObject).copy() as? HMEvent ?? $0 } }
                let oldEvents = copies(e.events), oldEnd = copies(e.endEvents)
                let oldPred = e.predicate, oldRec = e.recurrences, oldOnce = e.executeOnce, oldName = e.name
                let undo = Rollback()
                do {
                    if let ev = newEvents {
                        try await HK.run { e.updateEvents(ev, completionHandler: $0) }
                        undo.add("restored the events") { try await HK.run { e.updateEvents(oldEvents, completionHandler: $0) } }
                    }
                    if let ev = newEnd {
                        try await HK.run { e.updateEndEvents(ev, completionHandler: $0) }
                        undo.add("restored the end events") { try await HK.run { e.updateEndEvents(oldEnd, completionHandler: $0) } }
                    }
                    if touchPred {
                        try await HK.run { e.updatePredicate(pred, completionHandler: $0) }
                        undo.add("restored the conditions") { try await HK.run { e.updatePredicate(oldPred, completionHandler: $0) } }
                    }
                    if a.values["weekdays"] != nil {
                        try await HK.run { e.updateRecurrences(self.weekdayComponents(a), completionHandler: $0) }
                        undo.add("restored the weekdays") { try await HK.run { e.updateRecurrences(oldRec, completionHandler: $0) } }
                    }
                    if a.values["execute_once"] != nil {
                        try await HK.run { e.updateExecuteOnce(a.bool("execute_once") ?? false, completionHandler: $0) }
                        undo.add("restored execute_once") { try await HK.run { e.updateExecuteOnce(oldOnce, completionHandler: $0) } }
                    }
                    for s in addScenes {
                        try await HK.run { e.addActionSet(s, completionHandler: $0) }
                        undo.add("took \(s.name) back out") { try await HK.run { e.removeActionSet(s, completionHandler: $0) } }
                    }
                    for s in removeScenes {
                        try await HK.run { e.removeActionSet(s, completionHandler: $0) }
                        undo.add("put \(s.name) back") { try await HK.run { e.addActionSet(s, completionHandler: $0) } }
                    }
                    if let n = a.str("new_name") {
                        try await HK.run { e.updateName(n, completionHandler: $0) }
                        undo.add("restored the name") { try await HK.run { e.updateName(oldName, completionHandler: $0) } }
                    }
                } catch {
                    throw await undo.unwind(after: error)
                }
                return ["ok": true, "automation": e.name, "changes": changes,
                        "activation_state": activationState(e.triggerActivationState)] as [String: Any]
            }
            guard let tt = t as? HMTimerTrigger else { throw BridgeError.message("Unknown automation kind") }
            let newFire = try a.str("fire_date").map(fireDate)
            let touchRec = a.values["recurrence"] != nil
            if newFire != nil { changes.append("fire_date") }
            if touchRec { changes.append("recurrence") }
            if let n = a.str("new_name") { changes.append("name: \(n)") }
            guard !changes.isEmpty else { throw BridgeError.message("Nothing to change: fire_date, recurrence or new_name") }
            if dry { return ["dry_run": true, "automation": t.name, "changes": changes] as [String: Any] }
            let newRec = touchRec ? try recurrence(a) : nil   // validate before the first write
            let oldFire = tt.fireDate, oldRec = tt.recurrence, oldName = tt.name
            let undo = Rollback()
            do {
                if let f = newFire {
                    try await HK.run { tt.updateFireDate(f, completionHandler: $0) }
                    undo.add("restored the fire date") { try await HK.run { tt.updateFireDate(oldFire, completionHandler: $0) } }
                }
                if touchRec {
                    try await HK.run { tt.updateRecurrence(newRec, completionHandler: $0) }
                    undo.add("restored the recurrence") { try await HK.run { tt.updateRecurrence(oldRec, completionHandler: $0) } }
                }
                if let n = a.str("new_name") {
                    try await HK.run { tt.updateName(n, completionHandler: $0) }
                    undo.add("restored the name") { try await HK.run { tt.updateName(oldName, completionHandler: $0) } }
                }
            } catch {
                throw await undo.unwind(after: error)
            }
            return ["ok": true, "automation": tt.name, "changes": changes, "fire_date": tt.fireDate] as [String: Any]
        default:
            throw BridgeError.message("action must be get, create_event, create_timer or update")
        }
    }

    private func activationState(_ s: HMEventTriggerActivationState) -> String {
        switch s {
        case .enabled: return "enabled"
        case .disabled: return "disabled"
        case .disabledNoHomeHub: return "disabled_no_home_hub"
        case .disabledNoCompatibleHomeHub: return "disabled_no_compatible_home_hub"
        case .disabledNoLocationServicesAuthorization: return "disabled_no_location_permission"
        @unknown default: return "unknown"
        }
    }

    /// Events rows:
    ///   {accessory, characteristic, value}            fires when it becomes value
    ///   {accessory, characteristic, any_change: true} fires on any change
    ///   {accessory, characteristic, min?, max?}       fires when it enters the range
    ///   {button: accessory, press: 0|1|2, service_*?} programmable button
    ///   {time: "HH:MM" | "sunset-30" | "sunrise+15"}
    ///   {presence: first_arrives|last_leaves|any_arrives|any_leaves, who: anyone|me}
    ///   {latitude, longitude, radius_m, on: "enter"|"exit"}
    ///   {duration_seconds}                            end events only
    private func eventList(_ rows: [[String: Any]]?, _ home: HMHome, allowDuration: Bool) throws -> [HMEvent] {
        try (rows ?? []).map { row -> HMEvent in
            let r = Args(row)
            if let secs = r.int("duration_seconds") {
                guard allowDuration else { throw BridgeError.message("duration_seconds is only valid in end_events") }
                guard (1...86400).contains(secs) else { throw BridgeError.message("duration_seconds must be 1 to 86400") }
                return HMDurationEvent(duration: TimeInterval(secs))
            }
            if let t = r.str("time") { return try timeEvent(t).0 }
            if let p = r.str("presence") {
                var args = row; args["presence_who"] = r.str("who") ?? "anyone"
                return try triggerEvent("create_presence", Args(args), home).0
            }
            if let lat = r.values["latitude"] as? NSNumber, let lon = r.values["longitude"] as? NSNumber {
                let radius = (r.values["radius_m"] as? NSNumber)?.doubleValue ?? 100
                let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: lat.doubleValue, longitude: lon.doubleValue),
                                              radius: radius, identifier: "homekit-bridge-\(UUID().uuidString)")
                let on = (r.str("on") ?? "enter").lowercased()
                region.notifyOnEntry = on == "enter"
                region.notifyOnExit = on == "exit"
                return HMLocationEvent(region: region)
            }
            if let b = r.str("button") {
                var args = row; args["accessory_id"] = b; args["press_type"] = r.int("press") ?? 0
                return try triggerEvent("create", Args(args), home).0
            }
            var accs = home.accessories
            if let roomKey = r.str("room") { accs = accs.filter { $0.room?.name.caseInsensitiveCompare(roomKey) == .orderedSame } }
            let acc = try store.pick(accs, try r.req("accessory"), kind: "accessory", id: \.uniqueIdentifier, name: \.name)
            let (_, c) = try findCharacteristic(acc, try r.str("characteristic") ?? r.req("property"), r)
            try requireNotifying(c, acc.name)
            if r.values["min"] != nil || r.values["max"] != nil {
                let lo = (r.values["min"] as? NSNumber) ?? r.str("min").flatMap { Double($0) }.map { NSNumber(value: $0) }
                let hi = (r.values["max"] as? NSNumber) ?? r.str("max").flatMap { Double($0) }.map { NSNumber(value: $0) }
                let range: HMNumberRange
                if let lo, let hi {
                    guard lo.doubleValue <= hi.doubleValue else { throw BridgeError.message("min must not be greater than max") }
                    range = HMNumberRange(minValue: lo, maxValue: hi)
                }
                else if let lo { range = HMNumberRange(minValue: lo) }
                else if let hi { range = HMNumberRange(maxValue: hi) }
                else { throw BridgeError.message("min and max must be numbers") }
                return HMCharacteristicThresholdRangeEvent(characteristic: c, thresholdRange: range)
            }
            if r.bool("any_change") == true { return HMCharacteristicEvent<NSCopying>(characteristic: c, triggerValue: nil) }
            let v = try Names.parse(try r.req("value"), for: c)
            return HMCharacteristicEvent<NSCopying>(characteristic: c, triggerValue: copying(v))
        }
    }

    private func eventDetail(_ e: HMEvent) -> [String: Any] {
        if let t = e as? HMCharacteristicThresholdRangeEvent {
            return ["kind": "range", "accessory": t.characteristic.service?.accessory?.name ?? "?",
                    "characteristic": Names.name(for: t.characteristic.characteristicType),
                    "min": t.thresholdRange.minValue as Any, "max": t.thresholdRange.maxValue as Any]
        }
        if let l = e as? HMLocationEvent, let r = l.region as? CLCircularRegion {
            return ["kind": "location", "latitude": r.center.latitude, "longitude": r.center.longitude, "radius_m": r.radius,
                    "on": r.notifyOnEntry ? "enter" : "exit"]
        }
        return ["kind": "\(type(of: e))", "text": describe(e)]
    }

    /// Conditions: rows as in homekit_automations (characteristic or presence), plus
    /// {"any": [rows]} (OR), {"all": [rows]} (AND), {"not": row}, and time_after/time_before.
    private func conditionPredicate(_ a: Args, _ home: HMHome) throws -> NSPredicate? {
        var parts: [NSPredicate] = []
        if let rows = a.dicts("conditions") {
            for row in rows { parts.append(try conditionNode(row, home, depth: 0)) }
        }
        // Reuse the original time window logic (handles windows across midnight).
        var timeOnly = [String: Any]()
        if let v = a.values["time_after"] { timeOnly["time_after"] = v }
        if let v = a.values["time_before"] { timeOnly["time_before"] = v }
        if !timeOnly.isEmpty, let p = try buildPredicate(Args(timeOnly), home) { parts.append(p) }
        if parts.isEmpty { return nil }
        return parts.count == 1 ? parts[0] : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    private func conditionNode(_ row: [String: Any], _ home: HMHome, depth: Int) throws -> NSPredicate {
        guard depth < 8 else { throw BridgeError.message("conditions nest too deeply (8 levels at most)") }
        if let any = row["any"] as? [[String: Any]] {
            return NSCompoundPredicate(orPredicateWithSubpredicates: try any.map { try conditionNode($0, home, depth: depth + 1) })
        }
        if let all = row["all"] as? [[String: Any]] {
            return NSCompoundPredicate(andPredicateWithSubpredicates: try all.map { try conditionNode($0, home, depth: depth + 1) })
        }
        if let not = row["not"] as? [String: Any] {
            return NSCompoundPredicate(notPredicateWithSubpredicate: try conditionNode(not, home, depth: depth + 1))
        }
        guard let p = try buildPredicate(Args(["conditions": [row]]), home) else {
            throw BridgeError.message("empty condition")
        }
        return p
    }

    private struct SceneSource {
        let names: [String]
        /// Locks, garage doors and security systems these scenes would change.
        let sensitive: [String]
        /// Creates the inline scene if there is one, registering its removal with `undo`.
        let resolve: (Rollback) async throws -> [HMActionSet]
    }

    /// HomeKit refuses duplicate automation names (HMError 1); say so before changing anything.
    private func requireNewAutomationName(_ name: String, _ home: HMHome) throws {
        if home.triggers.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw BridgeError.message("An automation named \(name) already exists")
        }
    }

    /// scene_ids (several) or scene_id, or inline actions (a new scene named after the automation).
    private func scenesFor(_ a: Args, _ home: HMHome, name: String, dry: Bool) throws -> SceneSource {
        var keys = a.strings("scene_ids") ?? []
        if let one = a.str("scene_id") { keys.append(one) }
        if !keys.isEmpty {
            let sets = try keys.map { try store.scene($0, in: home) }
            return SceneSource(names: sets.map(\.name), sensitive: Sensitive.names(sets: sets), resolve: { _ in sets })
        }
        if home.actionSets.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw BridgeError.message("A scene named \(name) already exists; pass scene_ids or use another automation name")
        }
        let writes = try writeActions(a.dicts("actions"), home)
        return SceneSource(names: ["new scene \(name) (\(writes.count) actions)"],
                           sensitive: Sensitive.names(writes.map(\.0.characteristic)), resolve: { undo in
            let set: HMActionSet = try await HK.make { home.addActionSet(withName: name, completionHandler: $0) }
            undo.add("removed new scene \(name)") { try await HK.run { home.removeActionSet(set, completionHandler: $0) } }
            for (w, _) in writes { try await HK.run { set.addAction(w, completionHandler: $0) } }
            return [set]
        })
    }

    private func fireDate(_ s: String) throws -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard var d = f.date(from: s) ?? ISO8601DateFormatter().date(from: s) else {
            throw BridgeError.message("fire_date must be ISO 8601 with a time zone, e.g. 2026-12-01T07:30:00-08:00")
        }
        // HomeKit requires whole minutes and a time in the future.
        d = Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded(.down) * 60)
        guard d > Date() else { throw BridgeError.message("fire_date must be in the future") }
        return d
    }

    /// recurrence: {"every": N, "unit": "minute"|"hour"|"day"|"week"}. HomeKit accepts one unit;
    /// minutes must be 5 or more.
    private func recurrence(_ a: Args) throws -> DateComponents? {
        guard let r = a.values["recurrence"] as? [String: Any] else { return nil }
        let ra = Args(r)
        let n = ra.int("every") ?? 1
        guard n >= 1 else { throw BridgeError.message("recurrence every must be 1 or more") }
        var dc = DateComponents()
        switch (ra.str("unit") ?? "day").lowercased() {
        case "minute": guard n >= 5 else { throw BridgeError.message("minute recurrence must be 5 or more") }; dc.minute = n
        case "hour": dc.hour = n
        case "day": dc.day = n
        case "week": dc.weekOfYear = n
        default: throw BridgeError.message("recurrence unit must be minute, hour, day or week")
        }
        return dc
    }
}

// MARK: - camera snapshot helpers

@MainActor
final class CameraSnapshot: NSObject, HMCameraSnapshotControlDelegate {
    private var cont: CheckedContinuation<HMCameraSnapshot, Error>?
    private static var live: [CameraSnapshot] = []

    static func take(_ sc: HMCameraSnapshotControl) async throws -> HMCameraSnapshot {
        let helper = CameraSnapshot()
        live.append(helper)
        defer { live.removeAll { $0 === helper } }
        let previous = sc.delegate
        sc.delegate = helper
        defer { sc.delegate = previous }
        return try await withCheckedThrowingContinuation { c in
            helper.cont = c
            sc.takeSnapshot()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if let c = helper.cont { helper.cont = nil; c.resume(throwing: BridgeError.message("Snapshot timed out")) }
            }
        }
    }

    nonisolated func cameraSnapshotControl(_ cameraSnapshotControl: HMCameraSnapshotControl,
                                           didTake snapshot: HMCameraSnapshot?, error: Error?) {
        Task { @MainActor in
            guard let c = self.cont else { return }
            self.cont = nil
            if let snapshot { c.resume(returning: snapshot) }
            else { c.resume(throwing: error ?? BridgeError.message("No snapshot")) }
        }
    }

    static func render(_ snap: HMCameraSnapshot) -> Data? {
        let view = HMCameraView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
        view.cameraSource = snap
        view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { ctx in view.layer.render(in: ctx.cgContext) }
        return image.jpegData(compressionQuality: 0.6)
    }
}

// MARK: - discovery of unpaired accessories nearby (not in Mac Catalyst)

#if !targetEnvironment(macCatalyst)
@MainActor
final class AccessoryDiscovery: NSObject, HMAccessoryBrowserDelegate {
    private let browser = HMAccessoryBrowser()

    static func scan(seconds: Int) async throws -> [[String: Any]] {
        let d = AccessoryDiscovery()
        d.browser.delegate = d
        d.browser.startSearchingForNewAccessories()
        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        d.browser.stopSearchingForNewAccessories()
        return d.browser.discoveredAccessories.map {
            ["name": $0.name, "id": $0.uniqueIdentifier.uuidString, "category": $0.category.localizedDescription] as [String: Any]
        }
    }
}
#endif

import Foundation
import HomeKit
import SQLite3

/// private_ tools: Apple's undocumented HomeKit surface, as documented outside Apple
/// (class-dumped headers, the HomeClaw project's PRIVATE_API.md, the homekit-extractor project).
///
/// Ground rules:
///   - Everything goes through HBSafe (respondsToSelector + @try/@catch), so a selector that a macOS
///     update removes returns an error instead of crashing.
///   - homed (the HomeKit daemon) checks com.apple.homekit.private-spi-access for most private writes.
///     Apple grants it only to its own apps, so those writes fail cleanly with "Missing entitlement".
///     Reads of state homed already sent to this process usually work.
///   - The homed database is opened read-only. Nothing here writes to it.
///   - Nothing here needs SIP, AMFI or other system protections changed.
@MainActor
struct PrivateTools {
    let store: HomeStore

    // Properties worth trying per kind, from class-dumped HomeKit headers. Missing ones report an error.
    static let curated: [String: [String]] = [
        "manager": ["currentHomeKitUser", "status", "dataSyncState", "isResidentEnabled"],
        "home": ["applicationData", "residentDevices", "mediaSystems", "homeLocation", "isMultiUserEnabled",
                 "isAutomaticSoftwareUpdateEnabled", "isRemoteAccessAllowed", "networkRouterSupport",
                 "hasOnboardedForAccessCode", "hasOnboardedForWalletKey", "soundCheckEnabled", "users", "outgoingInvitations"],
        "accessory": ["applicationData", "settings", "softwareUpdateController", "softwareVersion", "mediaProfile",
                      "symptomsHandler", "wifiNetworkInfo", "networkProtectionGroup", "supportsMediaAccessControl",
                      "isFirmwareUpdateAvailable", "serialNumber", "productData", "accessoryProfiles", "category"],
        "service": ["applicationData", "configurationState", "defaultName", "serviceSubtype", "mediaSourceIdentifier",
                    "mediaSourceDisplayOrder", "lastSeenStatus", "isHidden"],
        "characteristic": ["applicationData", "notificationEnabledTime", "valueUpdatedTime"],
        "scene": ["applicationData", "isExecuting", "lastExecutionDate"],
        "automation": ["applicationData", "creatorDeviceIdentifier", "triggerOwnedActionSet", "isAutomaticallyCreated"],
        "room": ["applicationData"], "zone": ["applicationData"], "group": ["applicationData"],
    ]

    // MARK: private_probe

    func probe(_ a: Args) async throws -> Any {
        let action = a.str("action") ?? "describe"
        if action == "classes" {
            return HBClassNames(a.str("prefix") ?? "HM")
        }
        var target = try resolve(a)
        if let path = a.str("path") {
            for key in path.split(separator: ".").map(String.init) {
                // Key-value coding would run any zero-argument method with this name; allow declared properties only.
                guard HBPropertyNames(target).contains(key) else { throw BridgeError.message("path \(key): not a declared property of \(NSStringFromClass(type(of: target)))") }
                var out: AnyObject?
                if let err = HBSafeValueForKey(target, key, &out) { throw BridgeError.message("path \(key): \(err)") }
                guard let next = out else { throw BridgeError.message("path \(key) is nil") }
                target = next
            }
        }
        switch action {
        case "describe":
            return ["class": NSStringFromClass(type(of: target)), "properties": HBPropertyNames(target),
                    "methods": HBMethodNames(target).filter { !$0.hasPrefix(".") }] as [String: Any]
        case "read":
            let kind = a.str("kind") ?? "home"
            let keys = a.strings("keys") ?? (a.str("path") == nil ? (Self.curated[kind] ?? []) : HBPropertyNames(target))
            let depth = min(max(a.int("depth") ?? 1, 0), 3)
            var out: [String: Any] = ["class": NSStringFromClass(type(of: target))]
            var values: [String: Any] = [:], errors: [String: String] = [:]
            let declared = Set(HBPropertyNames(target))
            for k in keys {
                // Read declared properties only: key-value coding would also run any zero-argument method.
                guard declared.contains(k) else { errors[k] = "not a declared property"; continue }
                var v: AnyObject?
                if let err = HBSafeValueForKey(target, k, &v) { errors[k] = err; continue }
                values[k] = Self.render(v, depth: depth)
            }
            out["values"] = values
            if !errors.isEmpty { out["unavailable"] = errors }
            return out
        case "call":
            let sel = try a.req("selector")
            let args = try (a.values["arguments"] as? [Any] ?? []).map { try argument($0, a) }
            if a.bool("dry_run") ?? true {
                return ["dry_run": true, "class": NSStringFromClass(type(of: target)), "selector": sel,
                        "responds": (target as? NSObject)?.responds(to: NSSelectorFromString(sel)) ?? false,
                        "note": "Pass dry_run=false and confirm=true to call it. homed rejects most private writes from apps without Apple's private entitlement."] as [String: Any]
            }
            guard a.bool("confirm") == true else { throw BridgeError.message("private calls need confirm=true") }
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Any, Error>) in
                var resumed = false
                let err = HBSafeInvoke(target, sel, args) { result, error in
                    guard !resumed else { return }
                    resumed = true
                    if let error { c.resume(throwing: BridgeError.message("\(sel) failed: \(error.localizedDescription)")) }
                    else { c.resume(returning: ["ok": true, "selector": sel, "result": Self.render(result as AnyObject?, depth: 1)] as [String: Any]) }
                }
                if let err, !resumed { resumed = true; c.resume(throwing: BridgeError.message(err)); return }
                // A completion block that is never called would otherwise hang this request forever.
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    guard !resumed else { return }
                    resumed = true
                    c.resume(throwing: BridgeError.message("\(sel) did not call its completion within 30 s"))
                }
            }
        default:
            throw BridgeError.message("action must be classes, describe, read or call")
        }
    }

    /// kind: manager | home | accessory | service | characteristic | scene | automation | room | zone | group
    private func resolve(_ a: Args) throws -> AnyObject {
        let kind = a.str("kind") ?? "home"
        if kind == "manager" { return store.manager }
        let home = try store.home(a.str("home_id"))
        switch kind {
        case "home": return home
        case "accessory": return try store.accessory(try a.req("id"), in: home)
        case "service":
            let key = try a.req("id")
            if let hit = store.service(uuid: key, in: home) { return hit.1 }
            throw BridgeError.message("service needs a service UUID as id")
        case "characteristic":
            let acc = try store.accessory(try a.req("id"), in: home)
            let type = Names.characteristicType(for: try a.req("characteristic"))
            var services = acc.services
            if let sid = a.str("service_id") { services = services.filter { $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(sid) == .orderedSame } }
            guard let c = services.flatMap(\.characteristics).first(where: { $0.characteristicType == type }) else {
                throw BridgeError.message("\(acc.name) has no such characteristic")
            }
            return c
        case "scene": return try store.scene(try a.req("id"), in: home)
        case "automation": return try store.trigger(try a.req("id"), in: home)
        case "room": return try store.room(try a.req("id"), in: home)
        case "zone": return try store.zone(try a.req("id"), in: home)
        case "group": return try store.group(try a.req("id"), in: home)
        default: throw BridgeError.message("kind must be manager, home, accessory, service, characteristic, scene, automation, room, zone or group")
        }
    }

    /// Call arguments: JSON values pass through; "@home", "@accessory:<id>", "@scene:<id>", "@room:<id>",
    /// "@automation:<id>" become the HomeKit object.
    private func argument(_ v: Any, _ a: Args) throws -> Any {
        guard let s = v as? String, s.hasPrefix("@") else { return v }
        let home = try store.home(a.str("home_id"))
        let parts = s.dropFirst().split(separator: ":", maxSplits: 1).map(String.init)
        let key = parts.count > 1 ? parts[1] : ""
        guard let kind = parts.first else { throw BridgeError.message("Object reference \"\(s)\" needs a kind, e.g. @accessory:<id>") }
        switch kind {
        case "home": return home
        case "accessory": return try store.accessory(key, in: home)
        case "scene": return try store.scene(key, in: home)
        case "room": return try store.room(key, in: home)
        case "automation": return try store.trigger(key, in: home)
        default: return s
        }
    }

    static func render(_ v: AnyObject?, depth: Int) -> Any {
        guard let v else { return NSNull() }
        switch v {
        case let s as NSString: return s as String
        case let n as NSNumber: return n
        case let d as NSDate: return ISO8601DateFormatter().string(from: d as Date)
        case let u as NSUUID: return u.uuidString
        case let d as NSData: return ["bytes": d.length]
        case let arr as NSArray:
            return arr.prefix(50).map { render($0 as AnyObject, depth: depth - 1) }
        case let set as NSSet:
            return set.allObjects.prefix(50).map { render($0 as AnyObject, depth: depth - 1) }
        case let dict as NSDictionary:
            var out: [String: Any] = [:]
            for (k, val) in dict { out["\(k)"] = render(val as AnyObject, depth: depth - 1) }
            return out
        default:
            var out: [String: Any] = ["class": NSStringFromClass(type(of: v))]
            for k in ["name", "uniqueIdentifier"] {
                var x: AnyObject?
                if HBSafeValueForKey(v, k, &x) == nil, let x { out[k] = render(x, depth: 0) }
            }
            if depth > 0 {
                var props: [String: Any] = [:]
                for k in HBPropertyNames(v).prefix(40) where !["description", "debugDescription", "hash", "superclass"].contains(k) {
                    var x: AnyObject?
                    if HBSafeValueForKey(v, k, &x) == nil { props[k] = render(x, depth: depth - 1) }
                }
                out["properties"] = props
            } else {
                out["summary"] = String(String(describing: v).prefix(300))
            }
            return out
        }
    }

    // MARK: private_homed_db (read-only)

    /// homed's CoreData store. Reading it needs Full Disk Access for HomeKit Bridge (System Settings >
    /// Privacy & Security > Full Disk Access). It is a local copy and can lag the home hub.
    static var dbPath: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) + "/Library/HomeKit/core.sqlite" }
        return NSHomeDirectory() + "/Library/HomeKit/core.sqlite"
    }

    func homedDB(_ a: Args) throws -> Any {
        let db = try Self.open()
        defer { sqlite3_close(db) }
        let limit = min(max(a.int("limit") ?? 100, 1), 1000)
        switch a.str("action") ?? "tables" {
        case "tables":
            return try Self.rows(db, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name", limit: 2000).compactMap { $0["name"] }
        case "schema":
            let t = try a.req("table")
            guard t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { throw BridgeError.message("bad table name") }
            return try Self.rows(db, "PRAGMA table_info(\(t))", limit: 500)
        case "query":
            let sql = try a.req("sql").trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = sql.lowercased()
            guard lower.hasPrefix("select") || lower.hasPrefix("with") else { throw BridgeError.message("only SELECT queries") }
            guard !sql.dropLast(sql.hasSuffix(";") ? 1 : 0).contains(";") else { throw BridgeError.message("one statement only") }
            return try Self.rows(db, sql, limit: limit, decodeBlobs: a.bool("decode") ?? true)
        case "automation_actions":
            // Every action row with a blob, decoded. Shortcut-based automations keep their steps in a
            // binary plist (WFWorkflowActions) that Apple's public API never exposes.
            let tables = try Self.rows(db, "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'ZMKFACTION%'", limit: 20)
                .compactMap { $0["name"] as? String }
            guard tables.contains("ZMKFACTION") else {
                throw BridgeError.message("No ZMKFACTION table in this macOS version; use tables/schema to look around")
            }
            return try Self.rows(db, "SELECT * FROM ZMKFACTION", limit: limit, decodeBlobs: true)
        default:
            throw BridgeError.message("action must be tables, schema, query or automation_actions")
        }
    }

    private static func open() throws -> OpaquePointer {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw BridgeError.message("homed database not found at ~/Library/HomeKit/core.sqlite")
        }
        var db: OpaquePointer?
        for uri in ["file:\(dbPath)?mode=ro", "file:\(dbPath)?mode=ro&immutable=1"] {
            if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
               sqlite3_exec(db, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK {
                return db!
            }
            sqlite3_close(db); db = nil
        }
        throw BridgeError.message("Cannot read the homed database. Give HomeKit Bridge Full Disk Access in System Settings > Privacy & Security > Full Disk Access, then relaunch it.")
    }

    private static func rows(_ db: OpaquePointer, _ sql: String, limit: Int, decodeBlobs: Bool = false) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw BridgeError.message("SQL error: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_stmt_readonly(stmt) != 0 else { throw BridgeError.message("only read-only statements") }
        var out: [[String: Any]] = []
        while out.count < limit, sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT: row[name] = sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, i))
                    let data = (n > 0 ? sqlite3_column_blob(stmt, i) : nil).map { Data(bytes: $0, count: n) } ?? Data()
                    if decodeBlobs, let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                        row[name] = JSONValue.sanitize(plist)
                    } else if data.count == 16 {
                        row[name] = NSUUID(uuidBytes: [UInt8](data)).uuidString
                    } else {
                        row[name] = ["blob_bytes": n]
                    }
                default: row[name] = NSNull()
                }
            }
            out.append(row)
        }
        return out
    }
}

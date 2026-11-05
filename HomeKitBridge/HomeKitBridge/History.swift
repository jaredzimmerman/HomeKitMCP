import Foundation
import HomeKit
import SQLite3

/// Long-term HomeKit history, so Claude can later study how the home is actually used and propose
/// scenes and automations.
///
/// What it records (every home the Mac can see):
/// - readings: every change HomeKit reports for every readable, notifying characteristic
///   (lights on/off, brightness, color, motion, occupancy, light level, contact, temperature,
///   humidity, outlets, switches, buttons, locks' state, fans, blinds, sensors' status...),
///   deduplicated, plus a snapshot of all of them every 15 minutes and an hourly re-read of
///   mains-powered accessories to catch anything a notification missed.
/// - events: automation runs and scene runs (from lastFireDate / lastExecutionDate), reachability
///   changes, accessories added or removed, and the bridge's own control actions.
///
/// It never writes to HomeKit except to switch change notifications on for characteristics that
/// support them (the same thing the Home app does while it is open). Change notifications are
/// re-enabled on launch, whenever HomeKit reloads homes, when an accessory comes back, and every
/// 30 minutes.
///
/// Storage: ~/Library/Application Support/homekit-bridge/history.sqlite (WAL), kept forever unless
/// someone deletes rows. Read-only queries go through the homekit_history tool.
///
/// Hooks (two lines in HomeStore.swift, see PATCH-history.md):
///   didUpdateValueFor:  History.shared.change(accessory, service, characteristic)
///   log(_:_:):          History.shared.mirror(type, e, store: self)

private let HB_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - database (serial queue owner)

final class HistoryDB: @unchecked Sendable {
    let path: String
    private let queue = DispatchQueue(label: "homekit-bridge.history", qos: .utility)
    private var db: OpaquePointer?

    init(path: String) { self.path = path }

    static let schema = """
    PRAGMA journal_mode=WAL;
    PRAGMA synchronous=NORMAL;
    CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
    CREATE TABLE IF NOT EXISTS chars(
      id INTEGER PRIMARY KEY, uuid TEXT UNIQUE NOT NULL, home TEXT, room TEXT, zones TEXT,
      accessory TEXT, accessory_id TEXT, service TEXT, service_id TEXT, service_type TEXT,
      characteristic TEXT, char_type TEXT, format TEXT, units TEXT, battery INTEGER,
      first_seen REAL, last_seen REAL);
    CREATE TABLE IF NOT EXISTS readings(t REAL NOT NULL, cid INTEGER NOT NULL, v REAL, s TEXT, src INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS readings_t ON readings(t);
    CREATE INDEX IF NOT EXISTS readings_cid_t ON readings(cid, t);
    CREATE TABLE IF NOT EXISTS events(t REAL NOT NULL, home TEXT, type TEXT NOT NULL, name TEXT, object_id TEXT, detail TEXT);
    CREATE INDEX IF NOT EXISTS events_t ON events(t);
    CREATE INDEX IF NOT EXISTS events_type_t ON events(type, t);
    CREATE VIEW IF NOT EXISTS readings_named AS
      SELECT r.t AS t, datetime(r.t, 'unixepoch', 'localtime') AS local_time, c.home, c.room, c.zones, c.accessory,
             c.service, c.service_type, c.characteristic, r.v, r.s,
             CASE r.src WHEN 0 THEN 'change' WHEN 1 THEN 'snapshot' WHEN 2 THEN 'refresh' ELSE 'other' END AS source
      FROM readings r JOIN chars c ON c.id = r.cid;
    """

    func open() throws {
        try queue.sync {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var h: OpaquePointer?
            guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let handle = h else {
                let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
                sqlite3_close(h)
                throw BridgeError.message("history database: \(msg)")
            }
            sqlite3_busy_timeout(handle, 5000)
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(handle, HistoryDB.schema, nil, nil, &err) != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? "schema failed"
                sqlite3_free(err)
                sqlite3_close(handle)
                throw BridgeError.message("history database: \(msg)")
            }
            db = handle
        }
    }

    /// Fire-and-forget write on the history queue.
    func write(_ body: @escaping (OpaquePointer) -> Void) {
        queue.async { [self] in if let db { body(db) } }
    }

    /// Run on the history queue and hand the result back to an async caller.
    func read<T>(_ body: @escaping (OpaquePointer) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            queue.async { [self] in
                guard let db else { c.resume(throwing: BridgeError.message("history database is not open")); return }
                do { c.resume(returning: try body(db)) } catch { c.resume(throwing: error) }
            }
        }
    }

    // Helpers, called on the queue.

    static func exec(_ db: OpaquePointer, _ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    static func bind(_ stmt: OpaquePointer, _ params: [Any?]) {
        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            guard let p = param else { sqlite3_bind_null(stmt, idx); continue }
            switch p {
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, HB_TRANSIENT)
            default: sqlite3_bind_text(stmt, idx, "\(p)", -1, HB_TRANSIENT)
            }
        }
    }

    @discardableResult
    static func run(_ db: OpaquePointer, _ sql: String, _ params: [Any?] = []) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return false }
        defer { sqlite3_finalize(s) }
        bind(s, params)
        let rc = sqlite3_step(s)
        return rc == SQLITE_DONE || rc == SQLITE_ROW
    }

    static func rows(_ db: OpaquePointer, _ sql: String, _ params: [Any?] = [], limit: Int = 100_000,
                     readOnly: Bool = false, seconds: Double = 15) throws -> [[String: Any]] {
        if readOnly {
            // sqlite3_stmt_readonly also passes BEGIN, ROLLBACK, ATTACH and most PRAGMAs, which would
            // disturb the logger's own connection; allow plain queries only.
            let head = sql.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8).uppercased()
            guard head.hasPrefix("SELECT") || head.hasPrefix("WITH") || head.hasPrefix("EXPLAIN") else {
                throw BridgeError.message("only read-only statements (SELECT, WITH or EXPLAIN)")
            }
        }
        var stmt: OpaquePointer?
        // The tail points into the C string passed to prepare, so read it inside withCString.
        let (rc, rest): (Int32, String) = sql.withCString { cs in
            var tail: UnsafePointer<CChar>?
            let rc = sqlite3_prepare_v2(db, cs, -1, &stmt, &tail)
            return (rc, tail.map { String(cString: $0) } ?? "")
        }
        guard rc == SQLITE_OK, let s = stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw BridgeError.message("SQL error: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(s) }
        if readOnly {
            if sqlite3_stmt_readonly(s) == 0 { throw BridgeError.message("only read-only statements") }
            if !rest.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";"))).isEmpty {
                throw BridgeError.message("only one statement at a time")
            }
        }
        // A slow query would hold the only connection and stall recording; stop it after `seconds`.
        let deadline = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        deadline.pointee = Date().timeIntervalSince1970 + seconds
        sqlite3_progress_handler(db, 10_000, { ctx in
            guard let ctx else { return 0 }
            return Date().timeIntervalSince1970 > ctx.assumingMemoryBound(to: Double.self).pointee ? 1 : 0
        }, deadline)
        defer { sqlite3_progress_handler(db, 0, nil, nil); deadline.deallocate() }
        bind(s, params)
        var out: [[String: Any]] = []
        while out.count < limit {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { break }
            if rc == SQLITE_INTERRUPT { throw BridgeError.message("query took longer than \(Int(seconds)) s; narrow since/until or the filters") }
            guard rc == SQLITE_ROW else { throw BridgeError.message("SQL error: \(String(cString: sqlite3_errmsg(db)))") }
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(s) {
                let name = String(cString: sqlite3_column_name(s, i))
                switch sqlite3_column_type(s, i) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(s, i)
                case SQLITE_FLOAT:
                    let d = sqlite3_column_double(s, i)
                    row[name] = d.isFinite ? d : NSNull()
                case SQLITE_TEXT: row[name] = sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
                case SQLITE_NULL: row[name] = NSNull()
                default: row[name] = "(blob)"
                }
            }
            out.append(row)
        }
        return out
    }

    static func scalar(_ db: OpaquePointer, _ sql: String, _ params: [Any?] = []) -> Any? {
        (try? rows(db, sql, params, limit: 1))?.first?.values.first
    }
}

// MARK: - constants (no actor)

enum HistoryConst {
    // Static, identity and opaque control characteristics are not worth logging.
    static let suffix = "-0000-1000-8000-0026BB765291"
    static let skipTypes: Set<String> = Set(["00000023", "00000014", "00000052", "00000053", "00000054",
                                             "00000030", "00000021", "00000020", "0000001F", "000000E3",
                                             "00000037", "000000CB", "000000A6"].map { $0 + suffix })
    static let inputEvent = HMCharacteristicTypeInputEvent.uppercased()
    static let batteryService = "00000096" + suffix

    static func trackable(_ c: HMCharacteristic) -> Bool {
        let p = c.properties
        guard p.contains(HMCharacteristicPropertyReadable),
              p.contains(HMCharacteristicPropertySupportsEventNotification),
              !p.contains(HMCharacteristicPropertyHidden) else { return false }
        if skipTypes.contains(c.characteristicType.uppercased()) { return false }
        if let f = c.metadata?.format, f == HMCharacteristicMetadataFormatData || f == HMCharacteristicMetadataFormatTLV8 {
            return false
        }
        return true
    }

    static func isInputEvent(_ c: HMCharacteristic) -> Bool {
        c.characteristicType.uppercased() == inputEvent
    }

    static func hasBattery(_ a: HMAccessory) -> Bool {
        a.services.contains { $0.serviceType.uppercased() == batteryService }
    }

    static func encode(_ v: Any?) -> (Double?, String?) {
        guard let v, !(v is NSNull) else { return (nil, nil) }
        if let b = v as? Bool { return (b ? 1 : 0, nil) }
        if let n = v as? NSNumber { let d = n.doubleValue; return (d.isFinite ? d : nil, nil) }
        if let s = v as? String { return (nil, String(s.prefix(200))) }
        if v is Data { return (nil, nil) }
        return (nil, String("\(v)".prefix(200)))
    }

    static func upsert(_ db: OpaquePointer, _ m: [Any?]) {
        HistoryDB.run(db, """
            INSERT INTO chars(uuid,home,room,zones,accessory,accessory_id,service,service_id,service_type,characteristic,
                              char_type,format,units,battery,first_seen,last_seen)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(uuid) DO UPDATE SET home=excluded.home, room=excluded.room, zones=excluded.zones,
              accessory=excluded.accessory, service=excluded.service, service_type=excluded.service_type,
              characteristic=excluded.characteristic, format=excluded.format, units=excluded.units,
              battery=excluded.battery, last_seen=excluded.last_seen
            """, m)
    }
}

// MARK: - recorder

@MainActor
final class History {
    static let shared = History()

    private(set) var db: HistoryDB?
    private weak var store: HomeStore?
    private var started = false
    private var startError: String?
    private var paused = false

    private var cids: [UUID: Int64] = [:]                 // characteristic uuid -> chars.id
    private var lastValue: [Int64: (Double?, String?)] = [:]
    private var lastFire: [UUID: Date] = [:]
    private var lastSceneRun: [UUID: Date] = [:]
    private var firesPrimed = false

    private var ticker: Timer?
    private var tickCount = 0
    private var syncPending = false
    private var notifyRunning = false
    private var refreshRunning = false

    private(set) var lastSnapshot: Date?
    private(set) var lastRefresh: Date?
    private(set) var lastNotifyPass: Date?
    private var notifyEnabled = 0
    private var notifyFailed = 0
    private var notifyFailures: [String] = []
    private var lastChangeAt: [String: Date] = [:]        // home name -> last change recorded

    static let snapshotMinutes = 15
    static let refreshMinutes = 60
    static let notifyMinutes = 30

    static var path: String {
        TokenFile.directory.replacingOccurrences(of: "/.config/homekit-bridge",
                                                 with: "/Library/Application Support/homekit-bridge") + "/history.sqlite"
    }


    // MARK: lifecycle

    private func startIfNeeded(_ store: HomeStore) {
        guard !started else { return }
        started = true
        self.store = store
        let db = HistoryDB(path: History.path)
        do {
            try db.open()
            self.db = db
        } catch {
            startError = "\(error)"
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let p = try? await db.read { HistoryDB.scalar($0, "SELECT v FROM meta WHERE k='paused'") as? String }
            self.paused = (p ?? nil) == "1"
            self.event(type: "bridge_started", home: nil, name: BridgeConfig.version, id: nil, detail: nil)
            self.syncCharacteristics()
            self.primeLastValues()
        }
        let t = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in History.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        // First notification pass and snapshot shortly after HomeKit settles.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            await self?.enableNotifications(only: nil)
            self?.snapshot()
        }
    }

    private func tick() {
        guard db != nil else { return }
        tickCount += 1
        pollFires()
        if tickCount % History.snapshotMinutes == 0 { snapshot() }
        if tickCount % History.notifyMinutes == 0 { Task { await enableNotifications(only: nil) } }
        if tickCount % History.refreshMinutes == 7 { Task { await refresh() } }
        if tickCount % 60 == 0 { db?.write { HistoryDB.exec($0, "PRAGMA wal_checkpoint(PASSIVE)") } }
    }

    // MARK: hooks from HomeStore

    /// Every characteristic change HomeKit reports to the bridge.
    func change(_ accessory: HMAccessory, _ service: HMService, _ c: HMCharacteristic) {
        guard db != nil, !paused, HistoryConst.trackable(c) else { return }
        let home = homeName(of: accessory)
        record(c, accessory: accessory, service: service, home: home, src: 0, force: HistoryConst.isInputEvent(c))
        if let home { lastChangeAt[home] = Date() }
    }

    /// Mirrors HomeStore.log events into the database and reacts to home reloads.
    func mirror(_ type: String, _ detail: [String: Any], store: HomeStore) {
        startIfNeeded(store)
        guard db != nil else { return }
        switch type {
        case "characteristic_change":
            return
        case "homes_updated":
            scheduleSync()
        case "reachability_change":
            if (detail["reachable"] as? Bool) == true, let id = detail["id"] as? String {
                Task { await enableNotifications(only: id) }
            }
        default:
            break
        }
        guard !paused else { return }
        var d = detail
        d.removeValue(forKey: "time")
        d.removeValue(forKey: "type")
        let name = (d["accessory"] as? String) ?? (d["scene"] as? String) ?? (d["home"] as? String)
        event(type: type, home: d["home"] as? String, name: name, id: d["id"] as? String, detail: d)
    }

    // MARK: recording

    private func homeName(of accessory: HMAccessory) -> String? {
        store?.manager.homes.first(where: { $0.accessories.contains(where: { $0 === accessory }) })?.name
    }

    private func record(_ c: HMCharacteristic, accessory: HMAccessory, service: HMService, home: String?, src: Int,
                        force: Bool = false, at: Date = Date()) {
        guard let db else { return }
        let (v, s) = HistoryConst.encode(c.value)
        if v == nil && s == nil { return }
        let key = c.uniqueIdentifier
        let t = at.timeIntervalSince1970
        if let cid = cids[key] {
            if src == 0 && !force, let last = lastValue[cid], last.0 == v, last.1 == s { return }
            lastValue[cid] = (v, s)
            db.write { _ = HistoryDB.run($0, "INSERT INTO readings(t,cid,v,s,src) VALUES(?,?,?,?,?)", [t, cid, v, s, src]) }
        } else {
            // Not synced yet (new accessory): upsert its metadata first, then the reading.
            let meta = describe(c, accessory: accessory, service: service, home: home)
            let uuid = key.uuidString
            db.write { [weak self] h in
                HistoryConst.upsert(h, meta)
                guard let cid = HistoryDB.scalar(h, "SELECT id FROM chars WHERE uuid=?", [uuid]) as? Int64 else { return }
                HistoryDB.run(h, "INSERT INTO readings(t,cid,v,s,src) VALUES(?,?,?,?,?)", [t, cid, v, s, src])
                Task { @MainActor in self?.cids[key] = cid; self?.lastValue[cid] = (v, s) }
            }
        }
    }

    private func event(type: String, home: String?, name: String?, id: String?, detail: [String: Any]?) {
        guard let db else { return }
        var text: String?
        if let detail, !detail.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: JSONValue.sanitize(detail), options: [.sortedKeys]) {
            text = String(data: data, encoding: .utf8)
        }
        let t = Date().timeIntervalSince1970
        db.write { _ = HistoryDB.run($0, "INSERT INTO events(t,home,type,name,object_id,detail) VALUES(?,?,?,?,?,?)",
                                 [t, home, type, name, id, text]) }
    }

    private func describe(_ c: HMCharacteristic, accessory: HMAccessory, service: HMService, home: String?) -> [Any?] {
        let room = accessory.room?.name
        var zones: String?
        if let r = accessory.room, let h = store?.manager.homes.first(where: { $0.name == home }) {
            let z = h.zones.filter { $0.rooms.contains(where: { $0.uniqueIdentifier == r.uniqueIdentifier }) }.map(\.name)
            zones = z.isEmpty ? nil : z.sorted().joined(separator: ", ")
        }
        let battery = HistoryConst.hasBattery(accessory) ? 1 : 0
        let now = Date().timeIntervalSince1970
        return [c.uniqueIdentifier.uuidString, home, room, zones, accessory.name, accessory.uniqueIdentifier.uuidString,
                service.name, service.uniqueIdentifier.uuidString, Names.serviceName(for: service.serviceType),
                Names.name(for: c.characteristicType), c.characteristicType, c.metadata?.format, c.metadata?.units,
                battery, now, now]
    }

    private func tracked() -> [(HMHome, HMAccessory, HMService, HMCharacteristic)] {
        var out: [(HMHome, HMAccessory, HMService, HMCharacteristic)] = []
        for h in store?.manager.homes ?? [] {
            for a in h.accessories {
                for s in a.services {
                    for c in s.characteristics where HistoryConst.trackable(c) { out.append((h, a, s, c)) }
                }
            }
        }
        return out
    }

    private func scheduleSync() {
        guard !syncPending else { return }
        syncPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self else { return }
            self.syncPending = false
            self.syncCharacteristics()
            await self.enableNotifications(only: nil)
        }
    }

    /// Upserts names, rooms and zones for every tracked characteristic and refreshes the id cache.
    private func syncCharacteristics() {
        guard let db else { return }
        let metas = tracked().map { describe($0.3, accessory: $0.1, service: $0.2, home: $0.0.name) }
        db.write { [weak self] h in
            HistoryDB.exec(h, "BEGIN")
            for m in metas { HistoryConst.upsert(h, m) }
            HistoryDB.exec(h, "COMMIT")
            let rows = (try? HistoryDB.rows(h, "SELECT id, uuid FROM chars")) ?? []
            var map: [UUID: Int64] = [:]
            for r in rows {
                if let id = r["id"] as? Int64, let u = (r["uuid"] as? String).flatMap(UUID.init(uuidString:)) { map[u] = id }
            }
            Task { @MainActor in self?.cids.merge(map) { _, new in new } }
        }
    }

    /// Loads each characteristic's last stored value so a restart doesn't log duplicates.
    private func primeLastValues() {
        db?.write { [weak self] h in
            let rows = (try? HistoryDB.rows(h, """
                SELECT r.cid, r.v, r.s FROM readings r
                JOIN (SELECT cid, max(t) AS mt FROM readings GROUP BY cid) m ON m.cid = r.cid AND m.mt = r.t
                """)) ?? []
            var map: [Int64: (Double?, String?)] = [:]
            for r in rows {
                guard let cid = r["cid"] as? Int64 else { continue }
                map[cid] = ((r["v"] as? Double) ?? (r["v"] as? Int64).map(Double.init), r["s"] as? String)
            }
            Task { @MainActor in
                for (k, v) in map where self?.lastValue[k] == nil { self?.lastValue[k] = v }
            }
        }
    }

    /// Cached values of everything tracked on reachable accessories (input events excluded).
    private func snapshot() {
        guard let db, !paused else { return }
        let now = Date()
        var rows: [(Int64, Double?, String?)] = []
        var missing = false
        for (_, a, _, c) in tracked() where a.isReachable && !HistoryConst.isInputEvent(c) {
            guard let cid = cids[c.uniqueIdentifier] else { missing = true; continue }
            let (v, s) = HistoryConst.encode(c.value)
            if v == nil && s == nil { continue }
            rows.append((cid, v, s))
            lastValue[cid] = (v, s)
        }
        if missing { scheduleSync() }
        let t = now.timeIntervalSince1970
        db.write { h in
            HistoryDB.exec(h, "BEGIN")
            for r in rows { HistoryDB.run(h, "INSERT INTO readings(t,cid,v,s,src) VALUES(?,?,?,?,1)", [t, r.0, r.1, r.2]) }
            HistoryDB.run(h, "INSERT OR REPLACE INTO meta(k,v) VALUES('last_snapshot',?)", [String(t)])
            HistoryDB.exec(h, "COMMIT")
        }
        lastSnapshot = now
    }

    /// Re-reads mains-powered accessories to catch changes a notification missed.
    private func refresh() async {
        guard !refreshRunning, !paused else { return }
        refreshRunning = true
        defer { refreshRunning = false }
        let items = tracked().filter { $0.1.isReachable && !HistoryConst.isInputEvent($0.3) &&
            !HistoryConst.hasBattery($0.1) }
        for (h, a, s, c) in items {
            do { try await HK.runTimed(20) { c.readValue(completionHandler: $0) } } catch { continue }
            let after = HistoryConst.encode(c.value)
            let known = cids[c.uniqueIdentifier].flatMap { lastValue[$0] }
            if let known, known.0 == after.0, known.1 == after.1 { continue }
            record(c, accessory: a, service: s, home: h.name, src: 2)
        }
        lastRefresh = Date()
    }

    /// Switches change notifications on for every tracked characteristic that has them off.
    private func enableNotifications(only accessoryID: String?) async {
        guard !notifyRunning else { return }
        notifyRunning = true
        defer { notifyRunning = false }
        var ok = 0, failed = 0
        var failures: [String] = []
        for (_, a, _, c) in tracked() {
            if let accessoryID, a.uniqueIdentifier.uuidString != accessoryID { continue }
            guard a.isReachable else { continue }
            if c.isNotificationEnabled { ok += 1; continue }
            do {
                try await HK.runTimed(20) { c.enableNotification(true, completionHandler: $0) }
                ok += 1
            } catch {
                failed += 1
                if failures.count < 20 { failures.append("\(a.name) \(Names.name(for: c.characteristicType)): \(error.localizedDescription)") }
            }
        }
        if accessoryID == nil {
            notifyEnabled = ok
            notifyFailed = failed
            notifyFailures = failures
            lastNotifyPass = Date()
        }
    }

    /// Automation and scene runs, read from HomeKit's last-run dates once a minute.
    private func pollFires() {
        guard !paused else { return }
        for h in store?.manager.homes ?? [] {
            for t in h.triggers {
                guard let d = t.lastFireDate else { continue }
                if let prev = lastFire[t.uniqueIdentifier], d <= prev { continue }
                let first = lastFire[t.uniqueIdentifier] == nil
                lastFire[t.uniqueIdentifier] = d
                if first && !firesPrimed { continue }
                eventAt(d, type: "automation_ran", home: h.name, name: t.name, id: t.uniqueIdentifier.uuidString,
                        detail: ["enabled": t.isEnabled, "scenes": t.actionSets.map(\.name)])
            }
            for s in h.actionSets {
                guard let d = s.lastExecutionDate else { continue }
                if let prev = lastSceneRun[s.uniqueIdentifier], d <= prev { continue }
                let first = lastSceneRun[s.uniqueIdentifier] == nil
                lastSceneRun[s.uniqueIdentifier] = d
                if first && !firesPrimed { continue }
                eventAt(d, type: "scene_ran", home: h.name, name: s.name, id: s.uniqueIdentifier.uuidString,
                        detail: ["scene_type": s.actionSetType])
            }
        }
        firesPrimed = true
    }

    private func eventAt(_ date: Date, type: String, home: String?, name: String?, id: String?, detail: [String: Any]) {
        guard let db else { return }
        let text = (try? JSONSerialization.data(withJSONObject: JSONValue.sanitize(detail), options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
        let t = date.timeIntervalSince1970
        db.write { _ = HistoryDB.run($0, "INSERT INTO events(t,home,type,name,object_id,detail) VALUES(?,?,?,?,?,?)",
                                 [t, home, type, name, id, text]) }
    }

    // MARK: - tool

    func tool(_ a: Args) async throws -> Any {
        if let startError { throw BridgeError.message("history is not running: \(startError)") }
        guard let db else { throw BridgeError.message("history has not started yet (HomeKit still loading)") }
        let action = a.str("action") ?? "status"
        switch action {
        case "status": return try await status(db)
        case "devices": return try await devices(db, a)
        case "query": return try await query(db, a)
        case "events": return try await events(db, a)
        case "summary": return try await summary(db, a)
        case "sql":
            let sql = try a.req("sql")
            let limit = min(max(a.int("limit") ?? 500, 1), 5000)
            return try await db.read { try HistoryDB.rows($0, sql, [], limit: limit, readOnly: true) }
        case "pause", "resume":
            paused = action == "pause"
            let v = paused ? "1" : "0"
            db.write { _ = HistoryDB.run($0, "INSERT OR REPLACE INTO meta(k,v) VALUES('paused',?)", [v]) }
            event(type: action == "pause" ? "history_paused" : "history_resumed", home: nil, name: nil, id: nil, detail: nil)
            return ["recording": !paused]
        case "snapshot_now":
            snapshot()
            return ["done": "snapshot written", "at": ISO8601DateFormatter().string(from: Date())]
        case "notify_now":
            await enableNotifications(only: nil)
            return ["enabled": notifyEnabled, "failed": notifyFailed, "failures": notifyFailures]
        default:
            throw BridgeError.message("action must be status, devices, query, events, summary, sql, pause, resume, snapshot_now or notify_now")
        }
    }

    private func iso(_ d: Date?) -> Any { d.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull() }

    private func status(_ db: HistoryDB) async throws -> Any {
        let since24 = Date().addingTimeInterval(-86400).timeIntervalSince1970
        let stats = try await db.read { h -> [String: Any] in
            [
                "readings": HistoryDB.scalar(h, "SELECT count(*) FROM readings") ?? 0,
                "events": HistoryDB.scalar(h, "SELECT count(*) FROM events") ?? 0,
                "characteristics": HistoryDB.scalar(h, "SELECT count(*) FROM chars") ?? 0,
                "accessories": HistoryDB.scalar(h, "SELECT count(DISTINCT accessory_id) FROM chars") ?? 0,
                "oldest": HistoryDB.scalar(h, "SELECT datetime(min(t),'unixepoch','localtime') FROM readings") ?? NSNull(),
                "newest": HistoryDB.scalar(h, "SELECT datetime(max(t),'unixepoch','localtime') FROM readings") ?? NSNull(),
                "per_home_24h": (try? HistoryDB.rows(h, """
                    SELECT c.home, sum(r.src=0) AS changes, sum(r.src=1) AS snapshot_rows, sum(r.src=2) AS refresh_rows,
                           datetime(max(CASE WHEN r.src=0 THEN r.t END),'unixepoch','localtime') AS last_change
                    FROM readings r JOIN chars c ON c.id=r.cid WHERE r.t >= ? GROUP BY c.home
                    """, [since24])) ?? [],
            ]
        }
        let fm = FileManager.default
        func size(_ p: String) -> Int64 { ((try? fm.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.int64Value ?? 0 }
        let bytes = size(db.path) + size(db.path + "-wal")
        var homes: [[String: Any]] = []
        for h in store?.manager.homes ?? [] {
            let tr = tracked().filter { $0.0 === h }
            homes.append(["home": h.name, "hub": hubText(h.homeHubState), "tracked_characteristics": tr.count,
                          "reachable_accessories": h.accessories.filter(\.isReachable).count,
                          "accessories": h.accessories.count, "last_change_seen": iso(lastChangeAt[h.name])])
        }
        var out = stats
        out["recording"] = !paused
        out["database"] = db.path
        out["size_mb"] = (Double(bytes) / 1_048_576 * 10).rounded() / 10
        out["homes"] = homes
        out["notifications"] = ["enabled": notifyEnabled, "failed": notifyFailed, "last_pass": iso(lastNotifyPass),
                                "failures": notifyFailures] as [String: Any]
        out["last_snapshot"] = iso(lastSnapshot)
        out["last_refresh"] = iso(lastRefresh)
        out["schedule"] = "changes as they happen; snapshot every \(History.snapshotMinutes) min; re-read mains-powered every \(History.refreshMinutes) min; notifications re-enabled every \(History.notifyMinutes) min"
        return out
    }

    private func hubText(_ s: HMHomeHubState) -> String {
        switch s {
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .notAvailable: return "not_available"
        @unknown default: return "unknown"
        }
    }

    // MARK: filters

    /// ISO date or time, YYYY-MM-DD (local midnight), or relative: 30m, 12h, 7d, 4w.
    static func time(_ raw: String?, default def: TimeInterval?) throws -> Double? {
        guard let raw, !raw.isEmpty else { return def.map { Date().addingTimeInterval(-$0).timeIntervalSince1970 } }
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: "",
                                                                                          options: [.anchored])
        if let unit = s.last, "mhdw".contains(unit), let n = Double(s.dropLast()) {
            let mult: Double = unit == "m" ? 60 : unit == "h" ? 3600 : unit == "d" ? 86400 : 604800
            guard n.isFinite, n >= 0, n * mult <= 20 * 365 * 86400 else {
                throw BridgeError.message("relative time must be a number from 0 up to 20 years, e.g. 30m, 12h, 7d, 4w")
            }
            return Date().addingTimeInterval(-n * mult).timeIntervalSince1970
        }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: raw) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d.timeIntervalSince1970 }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = fmt
            if let d = local.date(from: raw) { return d.timeIntervalSince1970 }
        }
        throw BridgeError.message("could not read time \(raw); use ISO 8601, YYYY-MM-DD or 30m/12h/7d/4w")
    }

    /// WHERE clause over chars c for home/room/zone/accessory/service/characteristic filters.
    private func charFilter(_ a: Args, defaultCharacteristics: [String]? = nil) -> (String, [Any?]) {
        var w: [String] = []
        var p: [Any?] = []
        func eq(_ col: String, _ v: String?) {
            guard let v else { return }
            w.append("(lower(\(col)) = lower(?) OR \(col) = ?)"); p.append(v); p.append(v)
        }
        eq("c.home", a.str("home_id"))
        eq("c.room", a.str("room"))
        if let z = a.str("zone") { w.append("lower(c.zones) LIKE lower(?)"); p.append("%\(z)%") }
        if let acc = a.str("accessory_id") {
            w.append("(lower(c.accessory) = lower(?) OR c.accessory_id = upper(?))"); p.append(acc); p.append(acc)
        }
        if let ids = a.strings("accessories"), !ids.isEmpty {
            w.append("(" + ids.map { _ in "lower(c.accessory) = lower(?)" }.joined(separator: " OR ") + ")")
            p.append(contentsOf: ids.map { $0 as Any? })
        }
        eq("c.service", a.str("service_name"))
        var chars = a.strings("characteristics") ?? []
        if let one = a.str("characteristic") { chars.append(one) }
        if chars.isEmpty, let d = defaultCharacteristics { chars = d }
        if !chars.isEmpty {
            w.append("c.characteristic IN (" + chars.map { _ in "?" }.joined(separator: ",") + ")")
            p.append(contentsOf: chars.map { $0 as Any? })
        }
        return (w.isEmpty ? "1" : w.joined(separator: " AND "), p)
    }

    private func devices(_ db: HistoryDB, _ a: Args) async throws -> Any {
        let (w, p) = charFilter(a)
        let since = try History.time(a.str("since"), default: 7 * 86400) ?? 0
        return try await db.read { h in
            try HistoryDB.rows(h, """
                SELECT c.home, c.room, c.zones, c.accessory, c.service, c.service_type, c.characteristic, c.units,
                       c.battery = 1 AS battery_powered,
                       (SELECT count(*) FROM readings r WHERE r.cid=c.id AND r.src=0 AND r.t >= ?) AS changes,
                       (SELECT datetime(max(r.t),'unixepoch','localtime') FROM readings r WHERE r.cid=c.id AND r.src=0) AS last_change
                FROM chars c WHERE \(w) ORDER BY c.home, c.room, c.accessory, c.service, c.characteristic
                """, [since] as [Any?] + p, limit: 5000)
        }
    }

    private func query(_ db: HistoryDB, _ a: Args) async throws -> Any {
        let (w, p) = charFilter(a)
        let since = try History.time(a.str("since"), default: 86400) ?? 0
        let until = try History.time(a.str("until"), default: nil) ?? Date().timeIntervalSince1970 + 60
        let limit = min(max(a.int("limit") ?? 500, 1), 5000)
        let changesOnly = a.bool("changes_only") ?? true
        let src = changesOnly ? "AND r.src IN (0,2)" : ""
        return try await db.read { h in
            try HistoryDB.rows(h, """
                SELECT datetime(r.t,'unixepoch','localtime') AS time, c.room, c.accessory, c.service, c.characteristic,
                       r.v AS value, r.s AS text, CASE r.src WHEN 0 THEN 'change' WHEN 1 THEN 'snapshot' ELSE 'refresh' END AS source
                FROM readings r JOIN chars c ON c.id=r.cid
                WHERE r.t >= ? AND r.t < ? \(src) AND \(w)
                ORDER BY r.t DESC LIMIT ?
                """, [since, until] as [Any?] + p + [limit], limit: limit)
        }
    }

    private func events(_ db: HistoryDB, _ a: Args) async throws -> Any {
        let since = try History.time(a.str("since"), default: 7 * 86400) ?? 0
        let until = try History.time(a.str("until"), default: nil) ?? Date().timeIntervalSince1970 + 60
        let limit = min(max(a.int("limit") ?? 500, 1), 5000)
        var w = "t >= ? AND t < ?"
        var p: [Any?] = [since, until]
        if let type = a.str("type") { w += " AND type = ?"; p.append(type) }
        if let home = a.str("home_id") { w += " AND lower(home) = lower(?)"; p.append(home) }
        if let name = a.str("name") { w += " AND lower(name) LIKE lower(?)"; p.append("%\(name)%") }
        p.append(limit)
        return try await db.read { h in
            try HistoryDB.rows(h, """
                SELECT datetime(t,'unixepoch','localtime') AS time, home, type, name, detail FROM events
                WHERE \(w) ORDER BY t DESC LIMIT ?
                """, p, limit: limit)
        }
    }

    // MARK: summaries

    private static let stateChars = ["power", "motion_detected", "occupancy_detected", "contact_state", "active",
                                     "outlet_in_use", "in_use", "lock_current_state", "current_door_state", "input_event"]
    private static let presenceChars = ["motion_detected", "occupancy_detected"]
    private static let levelChars = ["current_light_level", "current_temperature", "current_humidity", "brightness"]

    private func summary(_ db: HistoryDB, _ a: Args) async throws -> Any {
        let kind = a.str("kind") ?? "occupancy"
        let since = try History.time(a.str("since"), default: 14 * 86400) ?? 0
        let until = try History.time(a.str("until"), default: nil) ?? Date().timeIntervalSince1970 + 60
        switch kind {
        case "occupancy":
            return try await intervals(db, a, since, until, defaults: History.presenceChars, label: "active")
        case "on_times":
            return try await intervals(db, a, since, until, defaults: ["power"], label: "on")
        case "levels":
            let (w, p) = charFilter(a, defaultCharacteristics: History.levelChars)
            return try await db.read { h in
                try HistoryDB.rows(h, """
                    SELECT c.room, c.accessory, c.characteristic, c.units,
                           CAST(strftime('%H', r.t, 'unixepoch', 'localtime') AS INTEGER) AS hour,
                           round(avg(r.v), 2) AS avg, min(r.v) AS min, max(r.v) AS max, count(*) AS samples
                    FROM readings r JOIN chars c ON c.id=r.cid
                    WHERE r.t >= ? AND r.t < ? AND r.v IS NOT NULL AND \(w)
                    GROUP BY c.id, hour ORDER BY c.room, c.accessory, c.characteristic, hour
                    """, [since, until] as [Any?] + p, limit: 20000)
            }
        case "activity":
            let (w, p) = charFilter(a, defaultCharacteristics: History.stateChars)
            return try await db.read { h in
                try HistoryDB.rows(h, """
                    SELECT coalesce(c.room, '(no room)') AS room,
                           CAST(strftime('%w', r.t, 'unixepoch', 'localtime') AS INTEGER) AS weekday,
                           CAST(strftime('%H', r.t, 'unixepoch', 'localtime') AS INTEGER) AS hour,
                           count(*) AS changes
                    FROM readings r JOIN chars c ON c.id=r.cid
                    WHERE r.t >= ? AND r.t < ? AND r.src = 0 AND \(w)
                    GROUP BY room, weekday, hour ORDER BY room, weekday, hour
                    """, [since, until] as [Any?] + p, limit: 20000)
            }
        case "co_changes":
            let window = Double(min(max(a.int("window_seconds") ?? 60, 1), 1800))
            let top = min(max(a.int("limit") ?? 50, 1), 500)
            let (w, p) = charFilter(a, defaultCharacteristics: History.stateChars)
            let wb = w.replacingOccurrences(of: "c.", with: "cb.")
            let params: [Any?] = [since, until] + p + [window] + p + [top]
            return try await db.read { h in
                try HistoryDB.rows(h, """
                    WITH ev AS (SELECT r.t, r.cid, r.v FROM readings r JOIN chars c ON c.id = r.cid
                                WHERE r.t >= ? AND r.t < ? AND r.src = 0 AND \(w)),
                         pairs AS (SELECT a.cid AS first, a.v AS first_value, b.cid AS then_cid, b.v AS then_value,
                                          b.t - a.t AS lag
                                   FROM ev a
                                   JOIN readings b ON b.t >= a.t AND b.t <= a.t + ? AND b.src = 0 AND b.cid != a.cid
                                                  AND (b.t > a.t OR b.cid > a.cid)
                                   JOIN chars cb ON cb.id = b.cid
                                   WHERE \(wb))
                    SELECT ca.room AS first_room, ca.accessory AS first_accessory, ca.characteristic AS first_characteristic,
                           p.first_value, cb.room AS then_room, cb.accessory AS then_accessory,
                           cb.characteristic AS then_characteristic, p.then_value, count(*) AS times,
                           round(avg(p.lag), 1) AS avg_lag_seconds,
                           (SELECT count(*) FROM ev WHERE ev.cid = p.first AND ev.v IS p.first_value) AS first_total
                    FROM pairs p JOIN chars ca ON ca.id = p.first JOIN chars cb ON cb.id = p.then_cid
                    GROUP BY p.first, p.first_value, p.then_cid, p.then_value
                    HAVING count(*) >= 2 ORDER BY times DESC LIMIT ?
                    """, params, limit: top)
            }
        case "automations":
            return try await db.read { h in
                try HistoryDB.rows(h, """
                    SELECT type, home, name, count(*) AS runs, datetime(min(t),'unixepoch','localtime') AS first,
                           datetime(max(t),'unixepoch','localtime') AS last
                    FROM events WHERE t >= ? AND t < ? AND type IN ('automation_ran','scene_ran','scene_triggered')
                    GROUP BY type, home, name ORDER BY runs DESC
                    """, [since, until], limit: 2000)
            }
        default:
            throw BridgeError.message("kind must be occupancy, on_times, levels, activity, co_changes or automations")
        }
    }

    /// On/active intervals per characteristic: count, total hours, average length, hour-of-day and
    /// weekday histograms of starts, and typical first start and last end per day (days run 4 AM to 4 AM).
    private func intervals(_ db: HistoryDB, _ a: Args, _ since: Double, _ until: Double,
                           defaults: [String], label: String) async throws -> Any {
        let (w, p) = charFilter(a, defaultCharacteristics: defaults)
        let raw = try await db.read { h in
            // The loop below only reacts when a value flips between zero and non-zero, so drop rows that
            // repeat the previous on/off state in SQL instead of loading every snapshot row into memory.
            try HistoryDB.rows(h, """
                SELECT cid, t, v, home, room, accessory, service, characteristic FROM (
                  SELECT r.cid, r.t, r.v, c.home, c.room, c.accessory, c.service, c.characteristic,
                         LAG(r.v != 0) OVER (PARTITION BY r.cid ORDER BY r.t) AS prev_on
                  FROM readings r JOIN chars c ON c.id=r.cid
                  WHERE r.t >= ? AND r.t < ? AND r.v IS NOT NULL AND \(w)
                ) WHERE prev_on IS NULL OR prev_on != (v != 0)
                ORDER BY cid, t
                """, [since, until] as [Any?] + p, limit: 300_000, seconds: 30)
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let end = min(until, Date().timeIntervalSince1970)

        struct Acc {
            var info: [String: Any] = [:]
            var on: Double? = nil
            var starts = 0
            var total = 0.0
            var byHour = [Int](repeating: 0, count: 24)
            var byWeekday = [Int](repeating: 0, count: 7)
            var firstStart: [Int: Double] = [:]   // day key -> minutes after 4 AM
            var lastEnd: [Int: Double] = [:]
        }
        var accs: [Int64: Acc] = [:]
        var order: [Int64] = []

        func dayKey(_ t: Double) -> (Int, Double) {
            let d = Date(timeIntervalSince1970: t - 4 * 3600)
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
            let key = (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
            return (key, Double((c.hour ?? 0) * 60 + (c.minute ?? 0)))
        }

        for r in raw {
            guard let cid = r["cid"] as? Int64, let t = r["t"] as? Double else { continue }
            let v = (r["v"] as? Double) ?? (r["v"] as? Int64).map(Double.init) ?? 0
            if accs[cid] == nil {
                var x = Acc()
                x.info = ["home": r["home"] ?? NSNull(), "room": r["room"] ?? NSNull(), "accessory": r["accessory"] ?? NSNull(),
                          "service": r["service"] ?? NSNull(), "characteristic": r["characteristic"] ?? NSNull()]
                accs[cid] = x
                order.append(cid)
            }
            var x = accs[cid]!
            let isOn = v != 0
            if isOn && x.on == nil {
                x.on = t
                x.starts += 1
                let comps = cal.dateComponents([.hour, .weekday], from: Date(timeIntervalSince1970: t))
                x.byHour[comps.hour ?? 0] += 1
                x.byWeekday[((comps.weekday ?? 1) - 1)] += 1
                let (k, m) = dayKey(t)
                if x.firstStart[k] == nil { x.firstStart[k] = m }
            } else if !isOn, let s = x.on {
                x.total += t - s
                x.on = nil
                let (k, m) = dayKey(t)
                x.lastEnd[k] = m
            }
            accs[cid] = x
        }

        func median(_ xs: [Double]) -> Double? {
            guard !xs.isEmpty else { return nil }
            let s = xs.sorted()
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
        func clock(_ minutesAfter4: Double?) -> Any {
            guard let m = minutesAfter4 else { return NSNull() }
            let total = (Int(m.rounded()) + 240) % 1440
            return String(format: "%02d:%02d", total / 60, total % 60)
        }

        var out: [[String: Any]] = []
        for cid in order {
            var x = accs[cid]!
            if let s = x.on { x.total += max(0, end - s) }
            var row = x.info
            row["\(label)_count"] = x.starts
            row["\(label)_hours_total"] = (x.total / 360).rounded() / 10
            row["avg_\(label)_minutes"] = x.starts > 0 ? ((x.total / Double(x.starts) / 60) * 10).rounded() / 10 : 0
            row["days_with_\(label)"] = x.firstStart.count
            row["typical_first_\(label)"] = clock(median(Array(x.firstStart.values)))
            row["typical_last_off"] = clock(median(Array(x.lastEnd.values)))
            row["starts_by_hour"] = x.byHour
            row["starts_by_weekday_sun_first"] = x.byWeekday
            row["\(label)_now"] = x.on != nil
            out.append(row)
        }
        return ["since": iso(Date(timeIntervalSince1970: since)), "until": iso(Date(timeIntervalSince1970: end)),
                "note": "Days run 4 AM to 4 AM local; times are local medians across days with activity.",
                "items": out] as [String: Any]
    }

    // MARK: - schema for tools/list

    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
    private static func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
    private static func oneOf(_ v: [String], _ d: String) -> [String: Any] { ["type": "string", "enum": v, "description": d] }
    private static func strs(_ d: String) -> [String: Any] { ["type": "array", "items": ["type": "string"], "description": d] }

    static var definitions: [[String: Any]] {
        let props: [String: Any] = [
            "action": oneOf(["status", "devices", "query", "events", "summary", "sql", "pause", "resume", "snapshot_now", "notify_now"], "Default status"),
            "kind": oneOf(["occupancy", "on_times", "levels", "activity", "co_changes", "automations"], "summary type"),
            "home_id": str("Home name"),
            "room": str("Room name"),
            "zone": str("Zone name"),
            "accessory_id": str("Accessory name or UUID"),
            "accessories": strs("Several accessory names"),
            "service_name": str("Service name"),
            "characteristic": str("Friendly name, e.g. power, brightness, motion_detected, occupancy_detected, current_light_level"),
            "characteristics": strs("Several friendly names"),
            "since": str("Start time (default: query 24h, devices/events 7d, summary 14d)"),
            "until": str("End time (default now)"),
            "type": str("events: event type"),
            "name": str("events: name contains"),
            "changes_only": bool("query: leave out snapshot rows (default true)"),
            "window_seconds": num("co_changes: max seconds between the two changes (default 60)"),
            "limit": num("Row cap (default 500, max 5000; co_changes default 50)"),
            "sql": str("sql: one read-only statement"),
        ]
        let desc = "Long-term HomeKit history recorded by the bridge on the Mac: every change of every notifying characteristic (lights, brightness, color, motion, occupancy, light level, contact, temperature, humidity, outlets, switches, buttons...) plus 15-minute snapshots and scene runs (automation runs cannot be recorded on a Mac). Read-only except pause/resume/snapshot_now/notify_now. Actions: status (size, counts, per-home recording health), devices (what is tracked, change counts), query (raw readings, newest first), events (automation_ran, scene_ran, scene_triggered, reachability_change, homes_updated, accessory_controlled, bridge_started), summary (kind: occupancy, on_times, levels, activity, co_changes, automations), sql (one read-only SELECT on tables chars, readings, events, meta and view readings_named; readings.t is unix seconds; src 0 change, 1 snapshot, 2 refresh). Times: ISO 8601, YYYY-MM-DD, or relative 30m/12h/7d/4w."
        let schema: [String: Any] = ["type": "object", "properties": props]
        return [["name": "homekit_history", "description": desc, "inputSchema": schema]]
    }
}

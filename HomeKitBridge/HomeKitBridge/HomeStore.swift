import Foundation
import HomeKit

/// Owns the HMHomeManager, waits for HomeKit to load, resolves names/UUIDs, and keeps a
/// small event log. Everything here runs on the main actor, where HomeKit calls back.
@MainActor
final class HomeStore: NSObject, HMHomeManagerDelegate, HMHomeDelegate, HMAccessoryDelegate {
    let manager = HMHomeManager()
    var onChange: (() -> Void)?
    private var loaded = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var events: [[String: Any]] = []

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorizationText: String {
        let s = manager.authorizationStatus
        if s.contains(.authorized) { return "allowed" }
        if s.contains(.determined) { return "denied (System Settings > Privacy & Security > Home)" }
        return "waiting for permission"
    }

    // MARK: loading

    func waitUntilLoaded() async throws {
        if !loaded {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiters.append(c)
                // HomeKit normally answers within a second; don't hang a request forever.
                Task { @MainActor [self] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    self.flushWaiters()
                }
            }
        }
        let s = manager.authorizationStatus
        if s.contains(.determined) && !s.contains(.authorized) {
            throw BridgeError.message("HomeKit access denied. Allow HomeKit Bridge in System Settings > Privacy & Security > Home.")
        }
        if manager.homes.isEmpty {
            throw BridgeError.message("No homes visible. Is this Mac signed in to the iCloud account that owns the home, and is Home access allowed?")
        }
    }

    private func flushWaiters() {
        let w = waiters
        waiters.removeAll()
        w.forEach { $0.resume() }
    }

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor [self] in
            loaded = true
            for home in manager.homes {
                home.delegate = self
                for acc in home.accessories { acc.delegate = self }
            }
            flushWaiters()
            log("homes_updated", ["homes": manager.homes.map(\.name)])
            onChange?()
        }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        Task { @MainActor [self] in onChange?() }
    }

    nonisolated func home(_ home: HMHome, didAdd accessory: HMAccessory) {
        Task { @MainActor [self] in
            accessory.delegate = self
            log("homes_updated", ["home": home.name, "added_accessory": accessory.name])
            onChange?()
        }
    }

    nonisolated func home(_ home: HMHome, didRemove accessory: HMAccessory) {
        Task { @MainActor [self] in
            log("homes_updated", ["home": home.name, "removed_accessory": accessory.name])
            onChange?()
        }
    }

    nonisolated func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        Task { @MainActor [self] in
            log("reachability_change", ["accessory": accessory.name, "id": accessory.uniqueIdentifier.uuidString,
                                        "reachable": accessory.isReachable])
        }
    }

    nonisolated func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        Task { @MainActor [self] in
            log("characteristic_change", ["accessory": accessory.name, "service": service.name,
                                          "characteristic": Names.name(for: characteristic.characteristicType),
                                          "value": JSONValue.sanitize(characteristic.value ?? NSNull())])
        }
    }

    func log(_ type: String, _ detail: [String: Any]) {
        var e = detail
        e["type"] = type
        e["time"] = ISO8601DateFormatter().string(from: Date())
        events.append(e)
        if events.count > 500 { events.removeFirst(events.count - 500) }
    }

    // MARK: resolution

    func home(_ idOrName: String?) throws -> HMHome {
        let homes = manager.homes
        if let key = idOrName, !key.isEmpty {
            if let h = homes.first(where: { $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(key) == .orderedSame }) { return h }
            let byName = homes.filter { $0.name.caseInsensitiveCompare(key) == .orderedSame }
            if byName.count == 1 { return byName[0] }
            if byName.count > 1 { throw BridgeError.message("Several homes are named \(key); pass the UUID.") }
            throw BridgeError.message("Home not found: \(key). Homes: \(homes.map(\.name).joined(separator: ", "))")
        }
        if let primary = homes.first(where: \.isPrimary) { return primary }
        if let first = homes.first { return first }
        throw BridgeError.message("No homes visible")
    }

    func pick<T>(_ items: [T], _ key: String, kind: String, id: (T) -> UUID, name: (T) -> String) throws -> T {
        if let u = items.first(where: { id($0).uuidString.caseInsensitiveCompare(key) == .orderedSame }) { return u }
        let matches = items.filter { name($0).caseInsensitiveCompare(key) == .orderedSame }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            let list = matches.map { "\(name($0)) = \(id($0).uuidString)" }.joined(separator: "; ")
            throw BridgeError.message("Several \(kind)s are named \(key). Pass a UUID: \(list)")
        }
        throw BridgeError.message("\(kind.capitalized) not found: \(key)")
    }

    func accessory(_ key: String, in home: HMHome) throws -> HMAccessory {
        try pick(home.accessories, key, kind: "accessory", id: \.uniqueIdentifier, name: \.name)
    }

    func room(_ key: String, in home: HMHome) throws -> HMRoom {
        let all = home.rooms + [home.roomForEntireHome()]
        return try pick(all, key, kind: "room", id: \.uniqueIdentifier, name: \.name)
    }

    func zone(_ key: String, in home: HMHome) throws -> HMZone {
        try pick(home.zones, key, kind: "zone", id: \.uniqueIdentifier, name: \.name)
    }

    func scene(_ key: String, in home: HMHome) throws -> HMActionSet {
        try pick(home.actionSets, key, kind: "scene", id: \.uniqueIdentifier, name: \.name)
    }

    func trigger(_ key: String, in home: HMHome) throws -> HMTrigger {
        try pick(home.triggers, key, kind: "automation", id: \.uniqueIdentifier, name: \.name)
    }

    func group(_ key: String, in home: HMHome) throws -> HMServiceGroup {
        try pick(home.serviceGroups, key, kind: "group", id: \.uniqueIdentifier, name: \.name)
    }

    /// A service UUID anywhere in the home.
    func service(uuid key: String, in home: HMHome) -> (HMAccessory, HMService)? {
        for a in home.accessories {
            for s in a.services where s.uniqueIdentifier.uuidString.caseInsensitiveCompare(key) == .orderedSame {
                return (a, s)
            }
        }
        return nil
    }
}

// MARK: - completion-handler bridges

@MainActor
enum HK {
    static func run(_ body: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            body { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    static func make<T>(_ body: (@escaping @Sendable (T?, Error?) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            body { value, error in
                if let error { c.resume(throwing: error) }
                else if let value { c.resume(returning: value) }
                else { c.resume(throwing: BridgeError.message("HomeKit returned nothing")) }
            }
        }
    }
}

// MARK: - rollback for multi-step writes

/// Undo steps for a change that takes several HomeKit calls. Register an undo right after each
/// step succeeds; if a later step throws, `unwind(after:)` runs them newest first and returns an
/// error that says what was put back and what could not be.
@MainActor
final class Rollback {
    private var steps: [(label: String, undo: () async throws -> Void)] = []

    func add(_ label: String, _ undo: @escaping () async throws -> Void) {
        steps.append((label, undo))
    }

    func unwind(after error: Error) async -> Error {
        guard !steps.isEmpty else { return error }
        var undone: [String] = []
        var failed: [String] = []
        for step in steps.reversed() {
            do {
                try await step.undo()
                undone.append(step.label)
            } catch {
                failed.append("\(step.label) (\((error as? BridgeError)?.description ?? error.localizedDescription))")
            }
        }
        steps.removeAll()
        var message = "\(error)"
        if !undone.isEmpty { message += " Rolled back: \(Rollback.summarize(undone))." }
        if !failed.isEmpty { message += " Could not undo: \(failed.joined(separator: "; ")); check the Home app." }
        return BridgeError.message(message)
    }

    /// "restored an old action; restored an old action" -> "restored an old action (x2)".
    private static func summarize(_ labels: [String]) -> String {
        var out: [(String, Int)] = []
        for l in labels {
            if let last = out.last, last.0 == l { out[out.count - 1].1 += 1 } else { out.append((l, 1)) }
        }
        return out.map { $0.1 > 1 ? "\($0.0) (x\($0.1))" : $0.0 }.joined(separator: "; ")
    }
}

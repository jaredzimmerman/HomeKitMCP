import Foundation

/// Stateless MCP over Streamable HTTP with JSON responses: each POST carries one
/// JSON-RPC message and gets one JSON answer. No sessions, no server-sent events.
@MainActor
final class MCPHandler {
    private let tools: ToolRouter
    private static let protocols = ["2025-06-18", "2025-03-26", "2024-11-05"]

    init(tools: ToolRouter) { self.tools = tools }

    func handle(body: Data) async -> HTTPResponse {
        guard let json = try? JSONSerialization.jsonObject(with: body, options: []) else {
            return .json(400, rpcError(id: NSNull(), code: -32700, message: "Parse error"))
        }
        if let batch = json as? [[String: Any]] {
            var out: [[String: Any]] = []
            for msg in batch { if let r = await handleOne(msg) { out.append(r) } }
            return out.isEmpty ? .accepted : .json(200, out)
        }
        guard let msg = json as? [String: Any] else {
            return .json(400, rpcError(id: NSNull(), code: -32600, message: "Invalid request"))
        }
        guard let reply = await handleOne(msg) else { return .accepted }
        return .json(200, reply)
    }

    private func handleOne(_ msg: [String: Any]) async -> [String: Any]? {
        guard let method = msg["method"] as? String else { return nil } // a response or junk: ignore
        guard let id = msg["id"], !(id is NSNull) else { return nil }    // notification
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? MCPHandler.protocols[0]
            let version = MCPHandler.protocols.contains(asked) ? asked : MCPHandler.protocols[0]
            return result(id: id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "homekit-bridge", "version": BridgeConfig.version],
            ])
        case "ping":
            return result(id: id, [:])
        case "tools/list":
            return result(id: id, ["tools": ToolRouter.definitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let value = try await tools.call(name: name, args: args)
                return result(id: id, ["content": [["type": "text", "text": Self.text(value)]], "isError": false])
            } catch {
                return result(id: id, ["content": [["type": "text", "text": "\(error)"]], "isError": true])
            }
        default:
            return rpcError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func result(id: Any, _ r: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": r]
    }

    private func rpcError(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    static func text(_ value: Any) -> String {
        if let s = value as? String { return s }
        let safe = JSONValue.sanitize(value)
        if JSONSerialization.isValidJSONObject(safe),
           let d = try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        return "\(value)"
    }
}

enum JSONValue {
    /// Makes HomeKit values JSON-safe: Data becomes base64, dates ISO 8601, UUIDs strings.
    static func sanitize(_ v: Any) -> Any {
        // `someOptional as Any` keeps the Optional box; nil would otherwise print as the string "nil".
        let m = Mirror(reflecting: v)
        if m.displayStyle == .optional {
            return m.children.first.map { sanitize($0.value) } ?? NSNull()
        }
        switch v {
        case let d as [String: Any]: return d.mapValues { sanitize($0) }
        case let a as [Any]: return a.map { sanitize($0) }
        case let s as String: return s
        case let n as NSNumber: return n
        case let data as Data: return data.base64EncodedString()
        case let date as Date: return ISO8601DateFormatter().string(from: date)
        case let u as UUID: return u.uuidString
        case is NSNull: return NSNull()
        default: return "\(v)"
        }
    }
}

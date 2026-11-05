import Foundation
import Network

struct HTTPResponse {
    var status: Int
    var body: Data
    var headers: [String: String] = ["Content-Type": "application/json"]

    static func json(_ status: Int, _ object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: data)
    }
    static let accepted = HTTPResponse(status: 202, body: Data(), headers: [:])
}

/// Minimal HTTP/1.1 server for the MCP endpoint. Loopback only, one request per
/// connection, bearer token required, 1 MB body cap, simple rate limit.
// All mutable state is touched only on `queue` (listener and connections start on it).
final class HTTPServer: @unchecked Sendable {
    typealias Handler = (Data) async -> HTTPResponse

    private let port: UInt16
    private let token: Data
    private let handler: Handler
    private let queue = DispatchQueue(label: "homekit-bridge.http")
    private var listener: NWListener?
    private var windowStart = Date()
    private var windowCount = 0
    private var active = 0

    private static let maxBody = 1 << 20
    private static let perMinute = 120
    private static let maxActive = 4

    init(port: UInt16, token: String, handler: @escaping Handler) {
        self.port = port
        self.token = Data(token.utf8)
        self.handler = handler
    }

    /// Called on the server's queue: (true, nil) once listening, (false, reason) when the listener fails.
    var onState: (@Sendable (Bool, String?) -> Void)?

    func start() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw BridgeError.message("bad port") }
        // Loopback only (127.0.0.1 and ::1). The port must not be one `tailscale serve` listens on:
        // Network.framework refuses it then, even on loopback (BridgeConfig.port explains).
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onState?(true, nil)
            case .failed(let error):
                NSLog("homekit-bridge listener failed: \(error)")
                self?.onState?(false, "\(error)")
                listener.cancel()
                // Try again shortly (for example if something held the port at login).
                self?.queue.asyncAfter(deadline: .now() + 5) { [weak self] in try? self?.start() }
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ conn: NWConnection) {
        // Only loopback peers (tailscale serve connects from localhost).
        if case .hostPort(let host, _) = conn.endpoint {
            let h = "\(host)"
            if !(h.hasPrefix("127.") || h.hasPrefix("::1") || h.hasPrefix("::ffff:127.") || h == "localhost") {
                conn.cancel(); return
            }
        }
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > HTTPServer.maxBody + 16384 {
                self.send(conn, .json(413, ["error": "request too large"])); return
            }
            switch Request.parse(buf) {
            case .complete(let req):
                self.dispatch(conn, req)
            case .invalid:
                self.send(conn, .json(400, ["error": "bad request"]))
            case .incomplete:
                if isComplete || error != nil { conn.cancel(); return }
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func dispatch(_ conn: NWConnection, _ req: Request) {
        if req.path == "/healthz" && req.method == "GET" {
            send(conn, .json(200, ["ok": true, "version": BridgeConfig.version])); return
        }
        guard req.path == "/mcp" else { send(conn, .json(404, ["error": "not found"])); return }

        let host = (req.headers["host"] ?? "").lowercased()
        let hostOnly = host.hasPrefix("[") ? host : String(host.split(separator: ":").first ?? "")
        guard hostOnly == "localhost" || hostOnly == "127.0.0.1" || hostOnly.hasPrefix("100.")
                || hostOnly.hasSuffix(".ts.net") else {
            send(conn, .json(403, ["error": "host not allowed"])); return
        }

        let auth = req.headers["authorization"] ?? ""
        let given = auth.hasPrefix("Bearer ") ? Data(auth.dropFirst(7).trimmingCharacters(in: .whitespaces).utf8) : Data()
        guard constantTimeEqual(given, token) else {
            var r = HTTPResponse.json(401, ["error": "unauthorized"])
            r.headers["WWW-Authenticate"] = "Bearer"
            send(conn, r); return
        }

        guard req.method == "POST" else {
            var r = HTTPResponse.json(405, ["jsonrpc": "2.0", "error": ["code": -32000, "message": "Method not allowed"], "id": NSNull()])
            r.headers["Allow"] = "POST"
            send(conn, r); return
        }

        if Date().timeIntervalSince(windowStart) > 60 { windowStart = Date(); windowCount = 0 }
        // Count tool calls only: each connector call also sends initialize and notifications/initialized,
        // so counting every POST hit the limit after about 40 tool calls a minute.
        let isToolCall = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any])?["method"] as? String == "tools/call"
        if isToolCall { windowCount += 1 }
        if (isToolCall && windowCount > HTTPServer.perMinute) || active >= HTTPServer.maxActive {
            var r = HTTPResponse.json(429, ["error": "busy"])
            r.headers["Retry-After"] = "2"
            send(conn, r); return
        }

        active += 1
        let body = req.body
        Task {
            let response = await self.handler(body)
            self.queue.async {
                self.active -= 1
                self.send(conn, response)
            }
        }
    }

    private func send(_ conn: NWConnection, _ r: HTTPResponse) {
        var head = "HTTP/1.1 \(r.status) \(HTTPServer.reason(r.status))\r\n"
        for (k, v) in r.headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(r.body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(r.body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[a.startIndex + i] ^ b[b.startIndex + i] }
        return diff == 0
    }

    private static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        default: return "Error"
        }
    }
}

struct Request {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    enum Parse { case complete(Request), incomplete, invalid }

    static func parse(_ buf: Data) -> Parse {
        let sep = Data("\r\n\r\n".utf8)
        guard let range = buf.range(of: sep) else {
            return buf.count > 16384 ? .invalid : .incomplete
        }
        guard let headText = String(data: buf.subdata(in: buf.startIndex..<range.lowerBound), encoding: .utf8) else {
            return .invalid
        }
        let lines = headText.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true { return .invalid }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= (1 << 20) else { return .invalid }
        let bodyStart = range.upperBound
        guard buf.count - (bodyStart - buf.startIndex) >= length else { return .incomplete }
        let body = buf.subdata(in: bodyStart..<(bodyStart + length))
        var path = String(first[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        return .complete(Request(method: String(first[0]), path: path, headers: headers, body: body))
    }
}

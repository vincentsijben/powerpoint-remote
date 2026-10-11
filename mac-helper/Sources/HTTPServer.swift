import Foundation
import Network

/// Minimal HTTP server: serves the web app and a small JSON API (network fallback for Bluetooth).
final class HTTPServer {
    private let hub: Hub
    private let webRoot: URL
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var waiting: [(conn: NWConnection, timer: DispatchWorkItem)] = []
    private var clientsLastSeen: [String: Date] = [:]
    var onStatusChange: (() -> Void)?

    init(hub: Hub, webRoot: URL) {
        self.hub = hub
        self.webRoot = webRoot
        hub.onChange.append { [weak self] in self?.flushWaiting() }
    }

    var connectedCount: Int {
        let cutoff = Date().addingTimeInterval(-25)
        return clientsLastSeen.values.filter { $0 > cutoff }.count
    }

    func start(preferredPort: UInt16) {
        for p in preferredPort..<(preferredPort + 10) {
            guard let nwPort = NWEndpoint.Port(rawValue: p),
                  let l = try? NWListener(using: .tcp, on: nwPort) else { continue }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] st in
                if case .failed(let err) = st {
                    Log.write("HTTP listener failed: \(err)")
                    self?.listener = nil
                    self?.onStatusChange?()
                }
            }
            l.start(queue: .main)
            listener = l
            port = p
            Log.write("HTTP server on port \(p)")
            return
        }
        Log.write("HTTP server could not start")
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[buf.startIndex..<range.lowerBound], as: UTF8.self)
                self.route(head: head, conn: conn)
            } else if error != nil || isComplete || buf.count > 65536 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func route(head: String, conn: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return respond(conn, status: "400 Bad Request", body: Data()) }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") {
                headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let comps = URLComponents(string: String(parts[1])) ?? URLComponents()
        let path = comps.path
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] { query[item.name] = item.value ?? "" }

        guard path.hasPrefix("/api/") else { return serveStatic(path: path, conn: conn) }

        if case .hostPort(let host, _) = conn.endpoint { clientsLastSeen["\(host)"] = Date() }
        let pin = headers["x-ppt-pin"] ?? query["pin"] ?? ""
        guard pin == hub.pin else {
            return respondJSON(conn, ["type": "auth", "ok": false, "need": true, "wrong": !pin.isEmpty], status: "401 Unauthorized")
        }

        switch path {
        case "/api/auth":
            respondJSON(conn, ["type": "auth", "ok": true])
        case "/api/state":
            // Long poll: hold the request until the state version changes (max 20 s).
            if let v = Int(query["ver"] ?? ""), v == hub.version {
                let item = DispatchWorkItem { [weak self] in self?.finishWaiting(conn) }
                waiting.append((conn, item))
                DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: item)
            } else {
                respond(conn, status: "200 OK", type: "application/json", body: hub.stateJSON(allNotes: query["all"] == "1"))
            }
        case "/api/cmd":
            var c = query["c"] ?? ""
            if let n = query["n"], !n.isEmpty { c += " \(n)" }
            let ok = hub.handle(command: c)
            respondJSON(conn, ["ok": ok])
        case "/api/slide":
            let slide = Int(query["n"] ?? "") ?? 0
            let width = Int(query["w"] ?? "") ?? 1600
            let quality = Double(query["q"] ?? "") ?? 0.75
            if let jpeg = hub.images.jpeg(slide: slide, width: width, quality: quality) {
                respond(conn, status: "200 OK", type: "image/jpeg", body: jpeg, cache: "private, max-age=3600")
            } else {
                respond(conn, status: "404 Not Found", body: Data())
            }
        default:
            respond(conn, status: "404 Not Found", body: Data())
        }
    }

    private func flushWaiting() {
        let list = waiting
        waiting.removeAll()
        for w in list {
            w.timer.cancel()
            respond(w.conn, status: "200 OK", type: "application/json", body: hub.stateJSON(allNotes: false))
        }
    }

    private func finishWaiting(_ conn: NWConnection) {
        guard let i = waiting.firstIndex(where: { $0.conn === conn }) else { return }
        waiting.remove(at: i)
        respond(conn, status: "200 OK", type: "application/json", body: hub.stateJSON(allNotes: false))
    }

    // MARK: - Static files

    private static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8", "json": "application/json", "webmanifest": "application/manifest+json",
        "svg": "image/svg+xml", "png": "image/png", "ico": "image/x-icon",
    ]

    private func serveStatic(path: String, conn: NWConnection) {
        var rel = path.removingPercentEncoding ?? path
        if rel.hasSuffix("/") { rel += "index.html" }
        let file = webRoot.appendingPathComponent(rel).standardizedFileURL
        guard file.path.hasPrefix(webRoot.standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: file) else {
            return respond(conn, status: "404 Not Found", body: Data("Not found".utf8))
        }
        let type = Self.mimeTypes[file.pathExtension.lowercased()] ?? "application/octet-stream"
        respond(conn, status: "200 OK", type: type, body: data, cache: "no-store")
    }

    // MARK: - Responses

    private func respondJSON(_ conn: NWConnection, _ obj: [String: Any], status: String = "200 OK") {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        respond(conn, status: status, type: "application/json", body: data)
    }

    private func respond(_ conn: NWConnection, status: String, type: String = "text/plain", body: Data, cache: String = "no-store") {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n" +
            "Cache-Control: \(cache)\r\nConnection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Addresses

    /// Local IPv4 addresses that an iPad on the same network (or hotspot) could reach.
    static func localAddresses() -> [(name: String, ip: String)] {
        var result: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254.") { result.append((name, ip)) }
            }
        }
        return result
    }
}

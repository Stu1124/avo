import Foundation

/// One entry of ~/Library/Application Support/Avo/mcp.json → "servers".
struct MCPServerConfig: @unchecked Sendable {
    var name: String
    var command: String?
    var args: [String] = []
    var env: [String: String] = [:]
    var url: String?
    /// Extra HTTP headers for streamable-HTTP servers (e.g. Authorization).
    var headers: [String: String] = [:]
    var isHTTP: Bool { url != nil && !(url ?? "").isEmpty }
    var transport: String { isHTTP ? "http" : "stdio" }
}

struct MCPToolInfo: @unchecked Sendable {
    var name: String
    var title: String?
    var description: String
    var inputSchema: [String: Any]
    var annotations: [String: Any]
}

struct MCPError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var description: String { message }
}

/// MCP client speaking JSON-RPC 2.0 over stdio (newline-delimited) or Streamable HTTP.
/// Starts lazily on the first request; `shutdown()` after 10 minutes idle. Reconnects on the next request.
actor MCPClient {
    static let protocolVersion = "2025-06-18"
    static let idleTimeout: TimeInterval = 10 * 60

    let config: MCPServerConfig
    private(set) var initialized = false
    private(set) var serverInfo: [String: Any] = [:]
    private(set) var lastUsed = Date()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var idleTask: Task<Void, Never>?
    private var connecting: Task<Void, Error>?

    // stdio
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private var stderrTail: [String] = []

    // http
    private var sessionId: String?
    private var negotiatedVersion = MCPClient.protocolVersion

    init(config: MCPServerConfig) { self.config = config }

    var isRunning: Bool { initialized && (config.isHTTP || (process?.isRunning ?? false)) }

    // MARK: public API

    func listTools() async throws -> [MCPToolInfo] {
        try await ensureConnected()
        var out: [MCPToolInfo] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = [:]
            if let c = cursor { params["cursor"] = c }
            let res = try await request("tools/list", params: params, timeout: 30)
            for t in res["tools"] as? [[String: Any]] ?? [] {
                guard let n = t["name"] as? String else { continue }
                out.append(MCPToolInfo(name: n, title: t["title"] as? String,
                                       description: (t["description"] as? String) ?? "",
                                       inputSchema: (t["inputSchema"] as? [String: Any]) ?? ["type": "object", "properties": [:]],
                                       annotations: (t["annotations"] as? [String: Any]) ?? [:]))
            }
            cursor = res["nextCursor"] as? String
        } while cursor != nil && !(cursor ?? "").isEmpty
        return out
    }

    /// Raw tools/call result: {content: [...], structuredContent?, isError?}.
    func callTool(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
        try await ensureConnected()
        return try await request("tools/call", params: ["name": name, "arguments": arguments], timeout: 44)
    }

    func shutdown() {
        Log.info("MCP[\(config.name)]: shutdown")
        idleTask?.cancel(); idleTask = nil
        initialized = false
        sessionId = nil
        if let p = process {
            try? stdinHandle?.close()
            if p.isRunning { p.terminate() }
        }
        process = nil; stdinHandle = nil; buffer = Data()
        for (_, c) in pending { c.resume(throwing: MCPError("\(config.name) stopped")) }
        pending = [:]
    }

    // MARK: connection

    private func ensureConnected() async throws {
        touch()
        if isRunning { return }
        if let c = connecting { try await c.value; return }
        let t = Task { try await self.connect() }
        connecting = t
        defer { connecting = nil }
        try await t.value
    }

    private func connect() async throws {
        initialized = false
        if !config.isHTTP { try launchProcess() }
        let res = try await request("initialize", params: [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "avo", "version": "1.0"],
        ], timeout: 30)
        serverInfo = (res["serverInfo"] as? [String: Any]) ?? [:]
        if let v = res["protocolVersion"] as? String { negotiatedVersion = v }
        try await notify("notifications/initialized", params: [:])
        initialized = true
        Log.info("MCP[\(config.name)]: initialized (\(serverInfo["name"] ?? "?") \(serverInfo["version"] ?? ""), \(config.transport))")
        touch()
    }

    private func touch() {
        lastUsed = Date()
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleTimeout * 1e9))
            guard !Task.isCancelled, let self else { return }
            if await self.idleExpired() { await self.shutdown() }
        }
    }

    private func idleExpired() -> Bool { Date().timeIntervalSince(lastUsed) >= Self.idleTimeout - 1 && pending.isEmpty }

    // MARK: JSON-RPC

    private func request(_ method: String, params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let id = nextId; nextId += 1
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        if config.isHTTP {
            let reply = try await withTimeout(seconds: timeout) { try await self.httpSend(msg, expectReply: true) }
            guard let reply else { throw MCPError("\(config.name): empty reply to \(method)") }
            return try Self.unwrap(reply, server: config.name)
        }
        let reply: [String: Any] = try await withTimeout(seconds: timeout) {
            try await withCheckedThrowingContinuation { cont in
                Task { await self.send(msg, id: id, cont: cont) }
            }
        }
        return try Self.unwrap(reply, server: config.name)
    }

    private func notify(_ method: String, params: [String: Any]) async throws {
        let msg: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if config.isHTTP { _ = try await httpSend(msg, expectReply: false); return }
        try write(msg)
    }

    private static func unwrap(_ reply: [String: Any], server: String) throws -> [String: Any] {
        if let err = reply["error"] as? [String: Any] {
            let m = (err["message"] as? String) ?? "error"
            let code = (err["code"] as? NSNumber)?.intValue ?? 0
            throw MCPError("\(server): \(m)\(code != 0 ? " (\(code))" : "")")
        }
        if let r = reply["result"] as? [String: Any] { return r }
        if reply["result"] != nil { return ["value": reply["result"]!] }
        return [:]
    }

    // MARK: stdio transport

    private func launchProcess() throws {
        guard let command = config.command, !command.isEmpty else { throw MCPError("\(config.name): no command or url configured") }
        let p = Process()
        // Login shell so npx/uvx/bun and user PATH entries resolve; exec so the server owns the pipes.
        let line = "exec " + ([command] + config.args).map(Self.shellQuote).joined(separator: " ")
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", line]
        var env = ProcessInfo.processInfo.environment
        let home = Paths.home.path
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.cargo/bin"]
        env["PATH"] = (extra + [(env["PATH"] ?? "/usr/bin:/bin")]).joined(separator: ":")
        for (k, v) in config.env { env[k] = v }
        p.environment = env
        p.currentDirectoryURL = Paths.home
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            Task { await self.received(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let self else { return }
            let s = String(decoding: d, as: UTF8.self)
            Task { await self.stderrLine(s) }
        }
        p.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            Task { await self.terminated(status: proc.terminationStatus) }
        }
        do { try p.run() } catch { throw MCPError("\(config.name): could not launch '\(command)': \(error.localizedDescription)") }
        process = p
        stdinHandle = inPipe.fileHandleForWriting
        buffer = Data()
        Log.info("MCP[\(config.name)]: launched \(command) (pid \(p.processIdentifier))")
    }

    private static func shellQuote(_ s: String) -> String {
        if s.range(of: "^[A-Za-z0-9_./:=@%+-]+$", options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func send(_ msg: [String: Any], id: Int, cont: CheckedContinuation<[String: Any], Error>) {
        pending[id] = cont
        do { try write(msg) } catch { pending[id] = nil; cont.resume(throwing: error) }
    }

    private func write(_ msg: [String: Any]) throws {
        guard let h = stdinHandle, process?.isRunning == true else { throw MCPError("\(config.name) is not running") }
        guard JSONSerialization.isValidJSONObject(msg), let d = try? JSONSerialization.data(withJSONObject: msg) else { throw MCPError("bad JSON-RPC message") }
        do { try h.write(contentsOf: d + Data([0x0A])) } catch { throw MCPError("\(config.name): write failed: \(error.localizedDescription)") }
    }

    private func received(_ d: Data) {
        guard !d.isEmpty else { return }
        buffer.append(d)
        // Cap buffer at 5 MB to prevent OOM from misbehaving servers.
        if buffer.count > 5_000_000 {
            Log.warn("MCP[\(config.name)]: dropping oversized buffer (\(buffer.count) bytes)")
            buffer.removeAll(keepingCapacity: false)
            return
        }
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty, let obj = try? JSONSerialization.jsonObject(with: line) else { continue }
            if let m = obj as? [String: Any] { handle(m) } else if let arr = obj as? [[String: Any]] { arr.forEach(handle) }
        }
    }

    private func handle(_ m: [String: Any]) {
        let method = m["method"] as? String
        if let idv = m["id"], method == nil {
            let id = (idv as? NSNumber)?.intValue ?? Int((idv as? String) ?? "") ?? -1
            if let c = pending.removeValue(forKey: id) { c.resume(returning: m) }
            return
        }
        guard let method else { return }
        if let idv = m["id"] {
            // Server → client request. Answer the few we can; refuse the rest.
            var reply: [String: Any] = ["jsonrpc": "2.0", "id": idv]
            switch method {
            case "ping": reply["result"] = [String: Any]()
            case "roots/list": reply["result"] = ["roots": [[String: Any]]()]
            default: reply["error"] = ["code": -32601, "message": "Method not supported by Avo"]
            }
            try? write(reply)
        } else if method == "notifications/message", let p = m["params"] as? [String: Any] {
            Log.info("MCP[\(config.name)] log: \((JSON.string(p["data"]) ?? JSON.stringify(p["data"] ?? "")).prefix(200))")
        }
    }

    private func stderrLine(_ s: String) {
        for l in s.split(separator: "\n") where !l.isEmpty {
            stderrTail.append(String(l.prefix(300)))
            if stderrTail.count > 20 { stderrTail.removeFirst() }
        }
    }

    private func terminated(status: Int32) {
        Log.warn("MCP[\(config.name)]: exited \(status)\(stderrTail.isEmpty ? "" : " — " + stderrTail.suffix(3).joined(separator: " | "))")
        let tail = stderrTail.suffix(2).joined(separator: " | ")
        for (_, c) in pending { c.resume(throwing: MCPError("\(config.name) exited (\(status))\(tail.isEmpty ? "" : ": \(tail)")")) }
        pending = [:]
        initialized = false
        process = nil; stdinHandle = nil
    }

    // MARK: streamable HTTP transport

    /// POST one JSON-RPC message. Returns the matching response (JSON body or SSE `data:` event) or nil for notifications.
    private func httpSend(_ msg: [String: Any], expectReply: Bool, retry: Bool = true) async throws -> [String: Any]? {
        guard let urlStr = config.url, let url = URL(string: urlStr) else { throw MCPError("\(config.name): bad url") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let s = sessionId { req.setValue(s, forHTTPHeaderField: "Mcp-Session-Id") }
        for (k, v) in config.headers { req.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in config.env where k.lowercased().hasPrefix("header_") { req.setValue(v, forHTTPHeaderField: String(k.dropFirst(7)).replacingOccurrences(of: "_", with: "-")) }
        req.httpBody = try JSONSerialization.data(withJSONObject: msg)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MCPError("\(config.name): no HTTP response") }
        if let s = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !s.isEmpty { sessionId = s }
        if http.statusCode == 404, sessionId != nil, retry, (msg["method"] as? String) != "initialize" {
            // Session expired: re-initialize once and resend.
            sessionId = nil; initialized = false
            try await connect()
            return try await httpSend(msg, expectReply: expectReply, retry: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError("\(config.name): HTTP \(http.statusCode) \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        guard expectReply else { return nil }
        let wantId = (msg["id"] as? Int) ?? -1
        let ctype = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let text = String(decoding: data, as: UTF8.self)
        if ctype.contains("text/event-stream") {
            var found: [String: Any]?
            for event in text.components(separatedBy: "\n\n") {
                let payload = event.split(separator: "\n").filter { $0.hasPrefix("data:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                guard !payload.isEmpty, let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) else { continue }
                let msgs = (obj as? [[String: Any]]) ?? [(obj as? [String: Any]) ?? [:]]
                for m in msgs {
                    if let idv = m["id"], (idv as? NSNumber)?.intValue == wantId, m["method"] == nil { found = m }
                    else if m["method"] != nil && m["id"] == nil { handle(m) }
                }
            }
            return found ?? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        let obj = try? JSONSerialization.jsonObject(with: data)
        if let m = obj as? [String: Any] { return m }
        if let arr = obj as? [[String: Any]] { return arr.first { ($0["id"] as? NSNumber)?.intValue == wantId } ?? arr.first }
        throw MCPError("\(config.name): unreadable reply (\(ctype))")
    }
}

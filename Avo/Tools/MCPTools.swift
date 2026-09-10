import Foundation

/// Registry of user-configured MCP servers (~/Library/Application Support/Avo/mcp.json).
/// Clients are created lazily; each shuts itself down after 10 minutes idle.
@MainActor
final class MCPServers {
    static let shared = MCPServers()
    nonisolated static var configURL: URL { Paths.appSupport.appendingPathComponent("mcp.json") }
    nonisolated static let icon = "server.rack"

    private(set) var configs: [MCPServerConfig] = []
    private(set) var toolCounts: [String: Int] = [:]
    private(set) var errors: [String: String] = [:]
    private var clients: [String: MCPClient] = [:]

    /// Parse mcp.json: {"servers": {"name": {"command", "args", "env", "url", "headers"}}} (also accepts "mcpServers").
    @discardableResult
    func loadConfig() -> [MCPServerConfig] {
        configs = []
        errors = [:]
        guard let data = try? Data(contentsOf: Self.configURL) else { return [] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            errors["mcp.json"] = "Not valid JSON"; Log.warn("MCP: mcp.json is not valid JSON"); return []
        }
        let servers = (obj["servers"] as? [String: Any]) ?? (obj["mcpServers"] as? [String: Any]) ?? [:]
        for (name, v) in servers.sorted(by: { $0.key < $1.key }) {
            guard let s = v as? [String: Any] else { continue }
            var c = MCPServerConfig(name: name)
            c.command = s["command"] as? String
            c.args = (s["args"] as? [Any])?.compactMap { JSON.string($0) } ?? []
            c.env = (s["env"] as? [String: Any])?.compactMapValues { JSON.string($0) } ?? [:]
            c.url = s["url"] as? String
            c.headers = (s["headers"] as? [String: Any])?.compactMapValues { JSON.string($0) } ?? [:]
            if s["disabled"] as? Bool == true { continue }
            guard c.isHTTP || !(c.command ?? "").isEmpty else { errors[name] = "needs command or url"; continue }
            configs.append(c)
        }
        Log.info("MCP: \(configs.count) server(s) configured")
        return configs
    }

    func client(for name: String) -> MCPClient? {
        if let c = clients[name] { return c }
        guard let cfg = configs.first(where: { $0.name == name }) else { return nil }
        let c = MCPClient(config: cfg)
        clients[name] = c
        return c
    }

    /// Stops every running client and forgets it, so the next `discover()` starts fresh processes.
    /// Settings' "Restart servers" is the caller: without this it re-listed tools from the same
    /// long-lived stdio processes and nothing was actually restarted.
    func shutdownAll() async {
        let running = clients
        clients.removeAll()
        toolCounts.removeAll()
        for (_, c) in running { await c.shutdown() }
    }

    /// Stops one server's client. Half of taking a server out of service, and never the whole of it:
    /// the caller must also unregister its tools and reload `configs`, or the next call to a
    /// `mcp_<name>_*` tool finds the stale config here and starts the server again. `MCPServersModel.retire`
    /// is that caller.
    func shutdown(_ name: String) async {
        toolCounts[name] = nil
        guard let c = clients.removeValue(forKey: name) else { return }
        await c.shutdown()
    }

    func isRunning(_ name: String) async -> Bool {
        guard let c = clients[name] else { return false }
        return await c.isRunning
    }

    /// Start every configured server once, list its tools, and wrap them. Servers then idle out after 10 minutes.
    func discover() async -> [MCPTool] {
        loadConfig()
        guard !configs.isEmpty else { return [] }
        var out: [MCPTool] = []
        await withTaskGroup(of: (String, Result<[MCPToolInfo], Error>).self) { group in
            for cfg in configs {
                guard let client = client(for: cfg.name) else { continue }
                group.addTask {
                    do {
                        let tools = try await withTimeout(seconds: 60) { try await client.listTools() }
                        return (cfg.name, .success(tools))
                    } catch { return (cfg.name, .failure(error)) }
                }
            }
            for await (name, result) in group {
                switch result {
                case .success(let infos):
                    toolCounts[name] = infos.count
                    errors[name] = nil
                    out += infos.map { MCPTool(server: name, info: $0) }
                    Log.info("MCP[\(name)]: \(infos.count) tools (\(infos.prefix(12).map(\.name).joined(separator: ", ")))")
                case .failure(let e):
                    toolCounts[name] = 0
                    errors[name] = "\(e)"
                    Log.warn("MCP[\(name)]: discovery failed: \(e)")
                }
            }
        }
        return out.sorted { $0.name < $1.name }
    }
}

/// A remote MCP tool exposed to the model as `mcp_<server>_<tool>`.
struct MCPTool: Tool, @unchecked Sendable {
    let server: String
    let remoteName: String
    let name: String
    let description: String
    let params: [ToolParam]
    /// The server's JSON schema, verbatim (Tool.schema is rebuilt from `params`; see report).
    let rawSchema: [String: Any]
    let statusLabel: String
    let statusIcon = MCPServers.icon
    let group: String
    let confirmation: ConfirmationSpec?

    init(server: String, info: MCPToolInfo) {
        self.server = server
        remoteName = info.name
        name = Self.sanitize("mcp_\(server)_\(info.name)")
        var desc = info.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if desc.isEmpty { desc = info.title ?? info.name.replacingOccurrences(of: "_", with: " ") }
        description = String(desc.prefix(1500)) + " (Tool '\(info.name)' on the '\(server)' MCP server.)"
        rawSchema = info.inputSchema
        params = Self.params(from: info.inputSchema)
        group = Self.group(for: server)
        let verb = info.name.split(whereSeparator: { !$0.isLetter }).first.map(String.init)?.lowercased() ?? info.name.lowercased()
        statusLabel = "Running \(info.name)"
        let explicitlyReadOnly = info.annotations["readOnlyHint"] as? Bool == true
        // Unknown tools confirm. Only an explicit read-only annotation skips the card.
        if !explicitlyReadOnly {
            let ps = params
            let title = (info.title ?? info.name.replacingOccurrences(of: "_", with: " ")).capitalized
            let shown = (ps.filter(\.required) + ps.filter { !$0.required }).prefix(8)
            confirmation = ConfirmationSpec(
                icon: MCPServers.icon, title: title,
                subtitle: { args in
                    let firstText = ps.first { args[$0.name] is String && !(($0.type == "object") || ($0.type == "array")) }
                    return firstText.flatMap { JSON.string(args[$0.name])?.preview(70) } ?? "on \(server)"
                },
                fields: shown.map { p in
                    let multi = p.type == "object" || p.type == "array" || ["body", "content", "text", "message", "description", "notes"].contains(p.name.lowercased())
                    return (key: p.name, label: p.name.replacingOccurrences(of: "_", with: " ").capitalized, kind: multi ? .multiline : .text, required: p.required)
                },
                confirmLabel: ["delete", "remove", "trash"].contains(verb) ? "Delete" : "Run",
                destructive: info.annotations["destructiveHint"] as? Bool == true || ["delete", "remove", "trash"].contains(verb))
        } else {
            confirmation = nil
        }
    }

    /// The registry group every tool from one server shares. Settings' per-server switch and Remove
    /// unregister by this, so it has one definition.
    static func group(for server: String) -> String { "MCP: \(server)" }

    static func sanitize(_ s: String) -> String {
        let cleaned = s.map { ($0.isLetter && $0.isASCII) || ($0.isNumber && $0.isASCII) || $0 == "_" || $0 == "-" ? $0 : "_" }
        return String(String(cleaned).prefix(64))
    }

    // MARK: schema → params

    static func params(from schema: [String: Any]) -> [ToolParam] {
        let props = (schema["properties"] as? [String: Any]) ?? [:]
        let required = Set((schema["required"] as? [String]) ?? [])
        return props.keys.sorted().map { key in
            let p = (props[key] as? [String: Any]) ?? [:]
            let type = jsonType(p)
            var desc = (p["description"] as? String) ?? (p["title"] as? String) ?? ""
            if type == "object", let sub = p["properties"] as? [String: Any], !sub.isEmpty {
                desc += " Object fields: " + fieldSummary(sub, required: Set((p["required"] as? [String]) ?? []))
            }
            var items: String? = nil
            if type == "array", let it = p["items"] as? [String: Any] {
                items = jsonType(it)
                if items == "object", let sub = it["properties"] as? [String: Any], !sub.isEmpty {
                    desc += " Each item is an object with fields: " + fieldSummary(sub, required: Set((it["required"] as? [String]) ?? []))
                } else if let e = it["enum"] as? [Any] {
                    desc += " Item values: " + e.compactMap { JSON.string($0) }.joined(separator: ", ")
                }
            }
            if let d = p["default"] { desc += " Default: \(JSON.string(d) ?? JSON.stringify(d))." }
            var enums = (p["enum"] as? [Any])?.compactMap { JSON.string($0) }
            if enums?.isEmpty == true { enums = nil }
            if desc.isEmpty { desc = key.replacingOccurrences(of: "_", with: " ") }
            return ToolParam(key, type, desc.trimmingCharacters(in: .whitespaces), required: required.contains(key), enumValues: enums, items: items)
        }
    }

    private static func jsonType(_ p: [String: Any]) -> String {
        let allowed = ["string", "number", "integer", "boolean", "array", "object"]
        if let t = p["type"] as? String, allowed.contains(t) { return t }
        if let ts = p["type"] as? [String], let t = ts.first(where: { $0 != "null" && allowed.contains($0) }) { return t }
        if p["properties"] != nil { return "object" }
        if p["items"] != nil { return "array" }
        if let any = (p["anyOf"] ?? p["oneOf"]) as? [[String: Any]], let f = any.first(where: { ($0["type"] as? String) != "null" }) { return jsonType(f) }
        return "string"
    }

    private static func fieldSummary(_ props: [String: Any], required: Set<String>) -> String {
        props.keys.sorted().prefix(12).map { k in
            let p = (props[k] as? [String: Any]) ?? [:]
            let d = ((p["description"] as? String) ?? "").preview(60)
            return "\(k) (\(jsonType(p))\(required.contains(k) ? ", required" : ""))\(d.isEmpty ? "" : ": \(d)")"
        }.joined(separator: "; ") + "."
    }

    // MARK: run

    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        guard let client = await MCPServers.shared.client(for: server) else { return .fail("MCP server '\(server)' is not configured.") }
        // `show` is ours: `Tool.openAIDefinition` adds it to every read tool so the model can ask for
        // a card. The server never declared it, and a strict schema validator rejects the call, so it
        // must not travel any further than this process.
        var stripped = args
        if !params.contains(where: { $0.name == "show" }) { stripped["show"] = nil }
        let a = repair(stripped)
        do {
            let res = try await client.callTool(remoteName, arguments: a)
            return Self.result(res, tool: remoteName, server: server)
        } catch {
            return .fail("\(error)", guidance: "The MCP server call failed. Report the error to the user; do not retry with the same arguments.")
        }
    }

    /// Confirmation edits arrive as strings; put objects/arrays/numbers back into the shapes the schema declares.
    private func repair(_ args: [String: Any]) -> [String: Any] {
        var out = args
        for p in params {
            guard let v = args[p.name] else { continue }
            switch p.type {
            case "object":
                if let s = v as? String, let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] { out[p.name] = o }
            case "array":
                var parsed: Any? = nil
                if let s = v as? String { parsed = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [Any] }
                else if let parts = v as? [String] {
                    let joined = parts.joined(separator: ",")
                    if joined.hasPrefix("[") { parsed = try? JSONSerialization.jsonObject(with: Data(joined.utf8)) as? [Any] }
                    else if p.items == "number" || p.items == "integer" { parsed = parts.compactMap { Double($0) } }
                }
                if let parsed { out[p.name] = parsed }
            case "integer": if let s = v as? String, let n = Int(s) { out[p.name] = n }
            case "number": if let s = v as? String, let n = Double(s) { out[p.name] = n }
            case "boolean": if let s = v as? String { out[p.name] = (s as NSString).boolValue }
            default: break
            }
        }
        return out
    }

    // MARK: result → ToolResult

    static func result(_ res: [String: Any], tool: String, server: String) -> ToolResult {
        var texts: [String] = []
        var images = 0
        for c in res["content"] as? [[String: Any]] ?? [] {
            switch c["type"] as? String {
            case "text": if let t = c["text"] as? String { texts.append(t) }
            case "image", "audio": images += 1
            case "resource":
                if let r = c["resource"] as? [String: Any] {
                    if let t = r["text"] as? String { texts.append(t) } else if let u = r["uri"] as? String { texts.append("[resource \(u)]") }
                }
            case "resource_link": if let u = c["uri"] as? String { texts.append("[link \(c["name"] as? String ?? u): \(u)]") }
            default: break
            }
        }
        let text = texts.joined(separator: "\n")
        let structured = res["structuredContent"] as? [String: Any]
        if res["isError"] as? Bool == true {
            return .fail(text.isEmpty ? "\(tool) failed." : String(text.prefix(2000)))
        }
        // Glance: in structuredContent, in the result itself, or inside a JSON text block.
        var glance = glancePayload(structured) ?? glancePayload(res)
        var parsedText: Any? = nil
        if glance == nil, texts.count == 1, let d = texts.first?.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) {
            parsedText = obj
            glance = glancePayload(obj as? [String: Any])
        }
        var json: [String: Any] = ["ok": true]
        if let s = structured { json["result"] = strip(s) }
        else if let p = parsedText { json["result"] = (p as? [String: Any]).map(strip) ?? p }
        if json["result"] == nil || !text.isEmpty && parsedText == nil {
            json["text"] = String(text.prefix(12_000))
            if text.count > 12_000 { json["truncated"] = true }
        }
        if images > 0 { json["media"] = "\(images) non-text item(s) omitted" }
        var cards: [CardKind] = []
        if let g = glance, let card = glanceCard(g, server: server) { cards.append(card) }
        return .ok(json, cards: cards)
    }

    private static func glancePayload(_ obj: [String: Any]?) -> [String: Any]? {
        guard let obj else { return nil }
        return obj["_avo_glance"] as? [String: Any]
    }

    private static func strip(_ obj: [String: Any]) -> [String: Any] {
        var o = obj; o["_avo_glance"] = nil; return o
    }

    private static let glyphs: [String: String] = [
        "calendar": "calendar", "clock": "clock", "timer": "timer", "bed": "bed.double", "car": "car", "mail": "envelope", "message": "message",
        "music": "music.note", "sun": "sun.max", "moon": "moon", "cloud": "cloud", "rain": "cloud.rain", "star": "star", "folder": "folder",
        "file": "doc", "globe": "globe", "pin": "mappin", "phone": "phone", "person": "person", "heart": "heart", "bolt": "bolt",
        "check": "checkmark", "x": "xmark", "mic": "mic", "note": "note.text", "list": "list.bullet", "battery": "battery.100",
        "chart": "chart.bar", "dollar": "dollarsign.circle", "home": "house", "wifi": "wifi", "coffee": "cup.and.saucer", "plane": "airplane", "sparkle": "sparkles",
    ]
    private static func icon(_ v: Any?) -> String? {
        guard let s = JSON.string(v), !s.isEmpty else { return nil }
        return glyphs[s.lowercased()] ?? s
    }
    private static func tone(_ v: Any?) -> GlanceCard.Tone {
        switch JSON.string(v)?.lowercased() { case "good": return .good; case "bad": return .bad; case "accent": return .accent; default: return .neutral }
    }

    /// `{blocks: [{type: header|list|keyValue|text, ...}], source?, sourceIcon?}` → GlanceCard (≤3 blocks, ≤6 rows).
    static func glanceCard(_ g: [String: Any], server: String) -> CardKind? {
        var blocks: [GlanceCard.Block] = []
        for b in (g["blocks"] as? [[String: Any]] ?? []).prefix(3) {
            switch (b["type"] as? String ?? "").lowercased() {
            case "header":
                guard let t = JSON.string(b["title"]) else { continue }
                blocks.append(.header(title: String(t.prefix(60)), subtitle: JSON.string(b["subtitle"] ?? b["trailing"]), icon: icon(b["icon"] ?? b["appIcon"]) ?? MCPServers.icon))
            case "list":
                let rows = (b["rows"] as? [[String: Any]] ?? b["items"] as? [[String: Any]] ?? []).prefix(6).compactMap { r -> GlanceCard.Row? in
                    guard let t = JSON.string(r["title"] ?? r["label"]) else { return nil }
                    let badge = (r["badge"] as? [String: Any]).flatMap { JSON.string($0["text"]) }
                    return GlanceCard.Row(title: t, subtitle: JSON.string(r["subtitle"])?.preview(72), icon: icon(r["icon"]), trailing: JSON.string(r["trailing"]) ?? badge, tone: tone(r["tone"] ?? (r["badge"] as? [String: Any])?["tone"]), url: JSON.string(r["url"]))
                }
                if !rows.isEmpty { blocks.append(.list(rows: rows)) }
            case "keyvalue", "key_value":
                var pairs: [(String, String)] = []
                if let arr = b["pairs"] as? [[String: Any]] ?? b["items"] as? [[String: Any]] {
                    pairs = arr.compactMap { p in
                        guard let k = JSON.string(p["key"] ?? p["label"]), let v = JSON.string(p["value"]) else { return nil }
                        return (k, v)
                    }
                } else if let arr = b["pairs"] as? [[Any]] {
                    pairs = arr.compactMap { $0.count >= 2 ? (JSON.string($0[0]) ?? "", JSON.string($0[1]) ?? "") : nil }
                } else if let d = b["pairs"] as? [String: Any] {
                    pairs = d.keys.sorted().compactMap { k in JSON.string(d[k]).map { (k, $0) } }
                }
                if !pairs.isEmpty { blocks.append(.keyValue(pairs: Array(pairs.prefix(5)))) }
            case "text", "markdown":
                if let t = JSON.string(b["text"] ?? b["value"] ?? b["content"]), !t.isEmpty { blocks.append(.text(t.preview(400))) }
            default: continue
            }
        }
        guard !blocks.isEmpty else { return nil }
        let source = JSON.string(g["source"]) ?? server
        return .glance(GlanceCard(id: UUID(), blocks: blocks, source: source, sourceIcon: icon(g["sourceIcon"] ?? g["icon"]) ?? MCPServers.icon))
    }
}

enum MCPTools {
    static let group = "MCP"

    /// Discovers every configured server's tools (starts them once) and adds the read-only `list_mcp_servers`.
    static func all() async -> [Tool] {
        let remote = await MCPServers.shared.discover()
        Log.info("MCPTools: \(remote.count) remote tools")
        return [ListServers()] + remote
    }

    struct ListServers: Tool {
        let name = "list_mcp_servers"
        let description = "List the custom MCP servers configured in Avo's mcp.json with each server's transport, whether it is currently running, its tool count, and any startup error. Read-only. Use it when the user asks which MCP servers or integrations are set up, or why an mcp_* tool is missing. Nothing to add here: servers are configured in ~/Library/Application Support/Avo/mcp.json."
        let params: [ToolParam] = []
        let statusLabel = "Checking MCP servers"
        let statusIcon = MCPServers.icon
        let group = MCPTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let reg = await MCPServers.shared
            let configs = await reg.configs
            let counts = await reg.toolCounts
            let errors = await reg.errors
            var servers: [[String: Any]] = []
            var rows: [GlanceCard.Row] = []
            for c in configs {
                let running = await reg.isRunning(c.name)
                var j: [String: Any] = ["name": c.name, "transport": c.transport, "running": running, "tools": counts[c.name] ?? 0]
                if let u = c.url { j["url"] = u } else if let cmd = c.command { j["command"] = ([cmd] + c.args).joined(separator: " ") }
                if let e = errors[c.name] { j["error"] = e }
                servers.append(j)
                let sub = errors[c.name].map { "Error: \($0.preview(60))" } ?? (c.url ?? ([c.command ?? ""] + c.args).joined(separator: " ")).preview(60)
                rows.append(GlanceCard.Row(title: c.name, subtitle: sub, icon: c.isHTTP ? "globe" : "terminal", trailing: "\(counts[c.name] ?? 0) tools", tone: errors[c.name] != nil ? .bad : (running ? .good : .neutral)))
            }
            let path = MCPServers.configURL.path
            var json: [String: Any] = ["ok": true, "config_path": path, "count": servers.count, "servers": servers]
            if let e = errors["mcp.json"] { json["config_error"] = e }
            let card = servers.isEmpty
                ? Cards.note(source: "MCP", icon: MCPServers.icon, title: "No MCP servers", body: "Add servers to \(path.replacingOccurrences(of: Paths.home.path, with: "~")).")
                : Cards.glance(source: "MCP", icon: MCPServers.icon, header: ("MCP servers", "\(servers.count) configured"), rows: rows)
            return .ok(json, cards: [card])
        }
    }
}

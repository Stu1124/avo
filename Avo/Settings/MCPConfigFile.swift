import Foundation

/// Reading and rewriting `mcp.json`, with no UI and no file system attached, so the part that can
/// damage a user's configuration is testable on its own.
///
/// The file is the user's, not Avo's: it may use either accepted spelling of the servers key
/// (`servers` or `mcpServers`), and it may carry keys this build knows nothing about. Both survive
/// a rewrite.
enum MCPConfigFile {
    struct Server: Equatable {
        var name: String
        var command: String = ""
        /// Space-separated, as typed in the form.
        var args: String = ""
        var url: String = ""
        /// One `Key: value` per line.
        var headers: String = ""
        var disabled: Bool = false

        var isHTTP: Bool { !url.trimmingCharacters(in: .whitespaces).isEmpty }
        var transport: String { isHTTP ? "HTTP" : "stdio" }
        /// The one-line "what does this server actually run" for the settings row.
        var detail: String {
            isHTTP ? url : ([command] + args.split(separator: " ").map(String.init)).joined(separator: " ")
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case notJSON
        case nameMissing
        case targetMissing
        case badURL
        var description: String {
            switch self {
            case .notJSON: return "mcp.json is not valid JSON. Fix or remove it before adding a server here."
            case .nameMissing: return "Give the server a name."
            case .targetMissing: return "A stdio server needs a command; an HTTP server needs a URL."
            case .badURL: return "That URL needs an http:// or https:// scheme."
            }
        }
    }

    /// Every server in the file, sorted by name. An absent file is no servers, not an error.
    static func parse(_ data: Data?) throws -> [Server] {
        guard let data, !data.isEmpty else { return [] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.notJSON }
        return serversDict(root).compactMap { name, value -> Server? in
            guard let s = value as? [String: Any] else { return nil }
            let args = (s["args"] as? [Any])?.compactMap { $0 as? String } ?? []
            let headers = (s["headers"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
            return Server(name: name,
                          command: s["command"] as? String ?? "",
                          args: args.joined(separator: " "),
                          url: s["url"] as? String ?? "",
                          headers: headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"),
                          disabled: s["disabled"] as? Bool == true)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Adds one server, or edits one already in the file, and returns the new file contents.
    ///
    /// An edit merges: the form owns `command`, `args`, `url`, `headers` and `disabled`, and every
    /// other key on that server — `env` above all, which the form cannot show and users do use —
    /// is carried through untouched. Keys belonging to the transport the user did not pick are
    /// dropped, so an entry never claims to be both stdio and HTTP.
    static func upsert(_ server: Server, into data: Data?) throws -> Data {
        let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Failure.nameMissing }
        let url = server.url.trimmingCharacters(in: .whitespaces)
        let command = server.command.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty || !command.isEmpty else { throw Failure.targetMissing }
        if !url.isEmpty {
            guard let scheme = URL(string: url)?.scheme, scheme == "http" || scheme == "https" else { throw Failure.badURL }
        }
        return try mutate(data) { servers in
            var entry = servers[name] as? [String: Any] ?? [:]
            if !url.isEmpty {
                entry["url"] = url
                let headers = parseHeaders(server.headers)
                if headers.isEmpty { entry.removeValue(forKey: "headers") } else { entry["headers"] = headers }
                entry.removeValue(forKey: "command")
                entry.removeValue(forKey: "args")
            } else {
                entry["command"] = command
                let args = server.args.split(separator: " ").map(String.init)
                if args.isEmpty { entry.removeValue(forKey: "args") } else { entry["args"] = args }
                entry.removeValue(forKey: "url")
                entry.removeValue(forKey: "headers")
            }
            if server.disabled { entry["disabled"] = true } else { entry.removeValue(forKey: "disabled") }
            servers[name] = entry
        }
    }

    static func remove(_ name: String, from data: Data?) throws -> Data {
        try mutate(data) { $0.removeValue(forKey: name) }
    }

    static func setDisabled(_ name: String, _ disabled: Bool, in data: Data?) throws -> Data {
        try mutate(data) { servers in
            guard var s = servers[name] as? [String: Any] else { return }
            if disabled { s["disabled"] = true } else { s.removeValue(forKey: "disabled") }
            servers[name] = s
        }
    }

    static func parseHeaders(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty, !v.isEmpty { out[k] = v }
        }
        return out
    }

    // MARK: -

    private static func serversDict(_ root: [String: Any]) -> [String: Any] {
        (root["servers"] as? [String: Any]) ?? (root["mcpServers"] as? [String: Any]) ?? [:]
    }

    private static func mutate(_ data: Data?, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var root: [String: Any] = [:]
        if let data, !data.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.notJSON }
            root = obj
        }
        // Keep whichever spelling the file already uses; a new file gets the documented one.
        let key = root["mcpServers"] != nil && root["servers"] == nil ? "mcpServers" : "servers"
        var servers = serversDict(root)
        change(&servers)
        root[key] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}

// deps: Avo/Settings/MCPConfigFile.swift
import Foundation

/// The MCP editor rewrites a file the user may also edit by hand, so the rules that matter are:
/// nothing unknown is dropped, the file's own spelling of the servers key is kept, and a bad entry
/// is refused before anything is written.
@main
struct MCPConfigFileTests {
    static func main() {
        parsesBothSpellings()
        parseRejectsGarbage()
        addsStdioServer()
        addsHTTPServerWithHeaders()
        keepsUnknownKeys()
        editKeepsEnvAndOtherPerServerKeys()
        keepsTheFilesOwnServersSpelling()
        refusesIncompleteServers()
        removesAndDisables()
        print("PASS: mcp.json parsing, both key spellings, unknown-key and env preservation, validation, remove/disable")
    }

    // MARK: helpers

    private static func data(_ json: String) -> Data { Data(json.utf8) }
    private static func object(_ d: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }
    private static func servers(_ d: Data, key: String = "servers") -> [String: Any] {
        object(d)[key] as? [String: Any] ?? [:]
    }

    // MARK: cases

    private static func parsesBothSpellings() {
        let a = try! MCPConfigFile.parse(data(#"{"servers":{"one":{"command":"npx","args":["-y","x"]}}}"#))
        precondition(a.count == 1 && a[0].name == "one" && a[0].command == "npx" && a[0].args == "-y x")
        precondition(!a[0].isHTTP && a[0].transport == "stdio" && a[0].detail == "npx -y x")

        let b = try! MCPConfigFile.parse(data(#"{"mcpServers":{"two":{"url":"https://e.example/mcp"}}}"#))
        precondition(b.count == 1 && b[0].name == "two" && b[0].isHTTP && b[0].transport == "HTTP")

        // Sorted by name, case-insensitively, so the list does not reshuffle between launches.
        let c = try! MCPConfigFile.parse(data(#"{"servers":{"zed":{"command":"z"},"Alpha":{"command":"a"}}}"#))
        precondition(c.map(\.name) == ["Alpha", "zed"])

        // No file at all is no servers, not an error.
        precondition(try! MCPConfigFile.parse(nil).isEmpty)
        precondition(try! MCPConfigFile.parse(Data()).isEmpty)
    }

    private static func parseRejectsGarbage() {
        var threw = false
        do { _ = try MCPConfigFile.parse(data("not json at all")) } catch { threw = true }
        precondition(threw, "invalid JSON must surface, not read as an empty list")
    }

    private static func addsStdioServer() {
        var s = MCPConfigFile.Server(name: "linear")
        s.command = "npx"
        s.args = "-y linear-mcp"
        let out = try! MCPConfigFile.upsert(s, into: nil)
        let entry = servers(out)["linear"] as? [String: Any] ?? [:]
        precondition(entry["command"] as? String == "npx")
        precondition(entry["args"] as? [String] == ["-y", "linear-mcp"])
        precondition(entry["url"] == nil && entry["disabled"] == nil, "a stdio server carries no url and no disabled flag")
    }

    private static func addsHTTPServerWithHeaders() {
        var s = MCPConfigFile.Server(name: "remote")
        s.url = "https://example.com/mcp"
        s.headers = "Authorization: Bearer abc\nignored line\nX-Team:  avo  "
        let out = try! MCPConfigFile.upsert(s, into: nil)
        let entry = servers(out)["remote"] as? [String: Any] ?? [:]
        precondition(entry["url"] as? String == "https://example.com/mcp")
        let headers = entry["headers"] as? [String: String] ?? [:]
        precondition(headers == ["Authorization": "Bearer abc", "X-Team": "avo"], "got \(headers)")
        precondition(entry["command"] == nil)
    }

    private static func keepsUnknownKeys() {
        let original = data(#"{"version":3,"notes":"hand written","servers":{"old":{"command":"o","extra":true}}}"#)
        var s = MCPConfigFile.Server(name: "new")
        s.command = "n"
        let out = try! MCPConfigFile.upsert(s, into: original)
        let root = object(out)
        precondition(root["version"] as? Int == 3, "a key Avo does not know about must survive a rewrite")
        precondition(root["notes"] as? String == "hand written")
        let old = servers(out)["old"] as? [String: Any] ?? [:]
        precondition(old["extra"] as? Bool == true, "an untouched server keeps its own extra keys")
        precondition(servers(out)["new"] != nil)
    }

    /// Editing a server through the form must not delete the parts of it the form cannot show.
    /// `env` is the one that matters: it usually carries the server's API key.
    private static func editKeepsEnvAndOtherPerServerKeys() {
        let original = data(#"""
        {"servers":{"linear":{"command":"npx","args":["-y","old"],"env":{"LINEAR_API_KEY":"lin_abc"},"timeout":30}}}
        """#)
        var edited = MCPConfigFile.Server(name: "linear")
        edited.command = "npx"
        edited.args = "-y linear-mcp"
        let out = try! MCPConfigFile.upsert(edited, into: original)
        let entry = servers(out)["linear"] as? [String: Any] ?? [:]
        let env = entry["env"] as? [String: String] ?? [:]
        precondition(env == ["LINEAR_API_KEY": "lin_abc"], "an edit must not drop env; got \(env)")
        precondition(entry["timeout"] as? Int == 30, "an edit must not drop per-server keys Avo does not know")
        precondition(entry["args"] as? [String] == ["-y", "linear-mcp"], "the fields the form owns are still overwritten")

        // Switching a server to HTTP drops the stdio keys, so the entry never claims to be both,
        // and still keeps env.
        var moved = MCPConfigFile.Server(name: "linear")
        moved.url = "https://mcp.example/sse"
        let http = servers(try! MCPConfigFile.upsert(moved, into: out))["linear"] as? [String: Any] ?? [:]
        precondition(http["url"] as? String == "https://mcp.example/sse")
        precondition(http["command"] == nil && http["args"] == nil, "the stdio keys go when the transport changes")
        precondition((http["env"] as? [String: String]) == ["LINEAR_API_KEY": "lin_abc"])
    }

    private static func keepsTheFilesOwnServersSpelling() {
        let original = data(#"{"mcpServers":{"one":{"command":"a"}}}"#)
        var s = MCPConfigFile.Server(name: "two")
        s.command = "b"
        let out = try! MCPConfigFile.upsert(s, into: original)
        precondition(object(out)["servers"] == nil, "must not add a second servers key next to mcpServers")
        precondition(servers(out, key: "mcpServers").count == 2)
        // A new file gets the documented spelling.
        precondition(object(try! MCPConfigFile.upsert(s, into: nil))["servers"] != nil)
    }

    private static func refusesIncompleteServers() {
        func fails(_ s: MCPConfigFile.Server) -> Bool {
            do { _ = try MCPConfigFile.upsert(s, into: nil); return false } catch { return true }
        }
        precondition(fails(MCPConfigFile.Server(name: "  ")), "a nameless server is refused")
        precondition(fails(MCPConfigFile.Server(name: "x")), "neither command nor url is refused")
        var bad = MCPConfigFile.Server(name: "x")
        bad.url = "ftp://example.com"
        precondition(fails(bad), "a non-http scheme is refused")
        // And a refusal leaves the caller with nothing to write, so the file on disk is untouched.
    }

    private static func removesAndDisables() {
        let original = data(#"{"servers":{"a":{"command":"a"},"b":{"command":"b"}}}"#)
        let removed = try! MCPConfigFile.remove("a", from: original)
        precondition(servers(removed).keys.sorted() == ["b"])

        let off = try! MCPConfigFile.setDisabled("b", true, in: original)
        precondition((servers(off)["b"] as? [String: Any])?["disabled"] as? Bool == true)
        precondition(try! MCPConfigFile.parse(off).first { $0.name == "b" }?.disabled == true)

        let on = try! MCPConfigFile.setDisabled("b", false, in: off)
        precondition((servers(on)["b"] as? [String: Any])?["disabled"] == nil, "re-enabling removes the flag rather than writing false")

        // Naming a server that is not there is a no-op, not a crash.
        precondition(servers(try! MCPConfigFile.setDisabled("missing", true, in: original)).count == 2)
    }
}

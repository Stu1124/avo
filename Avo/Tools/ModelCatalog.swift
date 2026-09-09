import Foundation

/// Which models each coding agent can run, newest first, plus the default the CLI itself would pick.
/// Static list because neither CLI exposes a model listing; `codex` reads its default from ~/.codex/config.toml.
enum ModelCatalog {
    struct Model: Identifiable, Hashable { let id: String; let label: String }

    static let claude: [Model] = [
        .init(id: "fable", label: "Fable 5.1"),
        .init(id: "opus", label: "Opus 5"),
        .init(id: "sonnet", label: "Sonnet 5"),
        .init(id: "haiku", label: "Haiku 4.5"),
    ]
    static let codex: [Model] = [
        .init(id: "gpt-6-astra", label: "GPT-6 Astra"),
        .init(id: "gpt-5.16-soul", label: "GPT-5.16 Soul"),
        .init(id: "gpt-5.6-luna", label: "GPT-5.6 Luna"),
    ]
    static let claudeEfforts = ["low", "medium", "high", "max"]
    static let codexEfforts = ["low", "medium", "high", "xhigh"]

    static func models(for agent: String) -> [Model] { agent == "codex" ? codex : claude }
    static func efforts(for agent: String) -> [String] { agent == "codex" ? codexEfforts : claudeEfforts }

    /// Avo's default when the user names no model (from AVO_MEMORY: Opus 5 for medium Claude tasks,
    /// GPT-5.6 Luna for Codex; Astra only on request). Not the CLI's own default.
    static func defaultModel(for agent: String) -> Model {
        agent == "codex" ? codex.first { $0.id == "gpt-5.6-luna" }! : claude.first { $0.id == "opus" }!
    }
    /// What the CLI itself would run with no flag (Codex reads ~/.codex/config.toml).
    static func cliDefault(for agent: String) -> String? { agent == "codex" ? codexConfigModel() : nil }
    static func defaultEffort(for agent: String) -> String {
        if agent == "codex", let e = codexConfigEffort() { return e }
        return "high"
    }

    /// Display name for any id, including ones typed by the user or reported by the CLI.
    static func label(for id: String?, agent: String) -> String {
        guard let id, !id.isEmpty else { return defaultModel(for: agent).label }
        if let m = models(for: agent).first(where: { $0.id == id || id.hasPrefix($0.id) }) { return m.label }
        return prettify(id)
    }
    static func effortLabel(_ e: String?) -> String {
        switch (e ?? "").lowercased() {
        case "": return ""
        case "xhigh": return "Extra high"
        case "max", "maximum": return "Max"
        default: return (e ?? "").capitalized
        }
    }

    private static func prettify(_ id: String) -> String {
        var s = id.replacingOccurrences(of: "claude-", with: "").replacingOccurrences(of: "-", with: " ")
        s = s.replacingOccurrences(of: "gpt ", with: "GPT-")
        return s.split(separator: " ").map { w in
            let str = String(w)
            return str.hasPrefix("GPT") ? str : str.prefix(1).uppercased() + str.dropFirst()
        }.joined(separator: " ")
    }

    private static func codexConfig() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        return try? String(contentsOf: url, encoding: .utf8)
    }
    private static func codexConfigModel() -> String? {
        guard let cfg = codexConfig() else { return nil }
        for line in cfg.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("model ") || t.hasPrefix("model="), let q = t.firstIndex(of: "\"") {
                let rest = t[t.index(after: q)...]
                if let end = rest.firstIndex(of: "\"") { return String(rest[..<end]) }
            }
        }
        return nil
    }
    private static func codexConfigEffort() -> String? {
        guard let cfg = codexConfig() else { return nil }
        for line in cfg.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("model_reasoning_effort"), let q = t.firstIndex(of: "\"") {
                let rest = t[t.index(after: q)...]
                if let end = rest.firstIndex(of: "\"") { return String(rest[..<end]) }
            }
        }
        return nil
    }
}

extension String {
    /// One-line plain text from markdown: strips emphasis, code ticks, headings, bullets.
    var markdownStripped: String {
        var s = self
        for token in ["**", "__", "`", "###", "##", "#"] { s = s.replacingOccurrences(of: token, with: "") }
        s = s.replacingOccurrences(of: #"(?m)^\s*[-*]\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        return s.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

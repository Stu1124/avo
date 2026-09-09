import Foundation

/// Long-term memory: a plain markdown file Avo appends to, searches, and prunes.
enum MemoryTools {
    static func all() -> [Tool] { [RememberTool(), ForgetTool(), RecallTool()] }
    static let group = "Memory"
    static let icon = "brain"

    /// Refreshes the header of a memory file written by an earlier version. Call once at launch.
    static func refreshFileHeader() { MemoryStore.migrateHeaderIfNeeded() }
}

/// Line-based store over `Paths.memoryFile` (header block, then one "- [date] text" line per memory).
private enum MemoryStore {
    static let header = MemoryHeader.current

    /// Files written by earlier versions carry a header with the old app name in it. Replace that block once,
    /// keeping every other line — memories and anything the user typed around them — untouched.
    static func migrateHeaderIfNeeded() {
        guard let rewritten = MemoryHeader.rewrite(read()) else { return }
        write(rewritten)
        Log.info("Memory: refreshed the file header")
    }

    static func read() -> String {
        (try? String(contentsOf: Paths.memoryFile, encoding: .utf8)) ?? ""
    }

    static func write(_ text: String) {
        let dir = Paths.memoryFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: Paths.memoryFile, atomically: true, encoding: .utf8)
    }

    /// Memory lines only (skips the header block and blank lines).
    static func entries(in text: String? = nil) -> [String] {
        (text ?? read()).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
    }

    /// The memory text without its "- [yyyy-MM-dd] " prefix, for date-insensitive dedupe.
    static func body(of line: String) -> String {
        let stripped = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
        guard stripped.hasPrefix("["), let close = stripped.firstIndex(of: "]") else { return stripped }
        return String(stripped[stripped.index(after: close)...]).trimmingCharacters(in: .whitespaces)
    }

    static func append(_ line: String) -> Bool {
        var text = read()
        if text.isEmpty { text = header + "\n" }
        let incoming = body(of: line).lowercased()
        guard !entries(in: text).contains(where: { body(of: $0).lowercased() == incoming }) else { return false }
        if !text.hasSuffix("\n") { text += "\n" }
        text += line + "\n"
        write(text)
        return true
    }

    static func matches(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return entries().filter { $0.lowercased().contains(q) }
    }

    /// Drops every memory line containing `query` (case-insensitive). Returns what it removed.
    static func remove(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var removed: [String] = []
        let kept = read().components(separatedBy: .newlines).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- "), t.lowercased().contains(q) else { return true }
            removed.append(t)
            return false
        }
        if !removed.isEmpty { write(kept.joined(separator: "\n")) }
        return removed
    }

    static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static func card(header: String, body: String) -> CardKind {
        .glance(GlanceCard(id: UUID(),
                           blocks: [.header(title: header, subtitle: nil, icon: MemoryTools.icon), .text(body)],
                           source: "Memory", sourceIcon: MemoryTools.icon))
    }
}

// MARK: - remember

private struct RememberTool: Tool {
    let name = "remember"
    let description = """
    Save something the user asked Avo to remember (a link, a fact, a preference, a person). Use whenever the user says \
    remember/save this/keep this in mind/don't forget/note that — and whenever they state a lasting preference about how \
    Avo should behave ('always use my work email', 'I like short answers'). Write `text` as one self-contained line in the \
    third person that will still make sense months later: include the who/what plus any URL or detail, never a pronoun with \
    no referent ('remember this' → write what 'this' actually is, taking it from the conversation or the screen). One fact \
    per call; call it more than once for several facts. Do NOT use it for a task or a reminder with a time (those are \
    reminders), and do not call it for things the user merely mentioned in passing without asking you to keep them.
    """
    let params = [
        ToolParam("text", "string", "The memory as one self-contained line, third person, with the concrete detail or URL included. Not a pronoun and not a summary of the conversation.", required: true),
        ToolParam("kind", "string", "What sort of memory this is, when it is obvious. Omit if unsure.", enumValues: ["fact", "link", "preference", "person"])
    ]
    let statusLabel = "Remembering"
    let statusIcon = MemoryTools.icon
    let group = MemoryTools.group

    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        guard let raw = JSON.string(args["text"])?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .fail("text is required", guidance: "Call remember again with the full fact written as one line.")
        }
        let text = raw.replacingOccurrences(of: "\n", with: " ")
        let line = "- [\(MemoryStore.today())] \(text)"
        let added = MemoryStore.append(line)
        let kind = JSON.string(args["kind"])
        var json: [String: Any] = ["ok": true, "saved": added, "line": line, "total": MemoryStore.entries().count]
        if let kind { json["kind"] = kind }
        json["note"] = added ? "Saved to Avo memory. Confirm in one short line." : "Already in memory word for word; nothing added. Say it's already saved."
        return .ok(json, cards: [MemoryStore.card(header: added ? "Remembered" : "Already remembered", body: text)])
    }
}

// MARK: - forget

private struct ForgetTool: Tool {
    let name = "forget"
    let description = """
    Delete things from Avo's memory. Use when the user says forget/delete/remove that, 'that's not true anymore', or asks \
    you to drop something you saved. `query` is the words to match: every saved line containing it (case-insensitive) is \
    removed, so pass the distinctive part of the memory (a name, a URL, the subject) rather than a whole sentence or a \
    single common word. Call recall first if you are not sure what is stored. The user sees exactly what will be removed and \
    confirms before anything is deleted; deletion cannot be undone.
    """
    let params = [ToolParam("query", "string", "Words that identify the memories to delete. Matched case-insensitively against each saved line; keep it distinctive (a name, URL, or subject), not a common word.", required: true)]
    let statusLabel = "Forgetting"
    let statusIcon = "trash"
    let group = MemoryTools.group

    var confirmation: ConfirmationSpec? {
        ConfirmationSpec(icon: MemoryTools.icon,
                         title: "Forget",
                         subtitle: { args in
                             guard let q = JSON.string(args["query"]) else { return nil }
                             let hits = MemoryStore.matches(q)
                             if hits.isEmpty { return "No saved memory matches “\(q)”" }
                             let preview = hits.prefix(3).map { $0.replacingOccurrences(of: "- ", with: "") }.joined(separator: " · ")
                             return hits.count > 3 ? "\(hits.count) memories · \(preview)…" : preview
                         },
                         fields: [(key: "query", label: "Remove memories matching", kind: .text, required: true)],
                         confirmLabel: "Forget",
                         destructive: true)
    }

    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        guard let query = JSON.string(args["query"])?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return .fail("query is required", guidance: "Call forget again with the words that identify the memory.")
        }
        let removed = MemoryStore.remove(query)
        guard !removed.isEmpty else {
            return .ok(["ok": true, "removed": 0, "query": query,
                        "note": "Nothing in memory matched. Tell the user there was nothing saved like that; do not retry with a broader query unless they ask."])
        }
        let body = removed.prefix(6).map { $0.replacingOccurrences(of: "- ", with: "") }.joined(separator: "\n")
        return .ok(["ok": true, "removed": removed.count, "query": query, "lines": removed,
                    "remaining": MemoryStore.entries().count,
                    "note": "Deleted from Avo memory. Confirm in one short line."],
                   cards: [MemoryStore.card(header: "Forgotten", body: body)])
    }
}

// MARK: - recall

private struct RecallTool: Tool {
    let name = "recall"
    let description = """
    Look up what Avo has saved in its long-term memory. Use when the user asks what you remember ('what do you know about \
    X', 'what did I tell you about the campaign', 'what's saved'), and BEFORE forget when you are not sure what is stored. \
    Pass `query` to filter to lines containing those words (case-insensitive); omit it to get everything saved. Returns the \
    saved lines with the date each was stored. If it comes back empty, say nothing is saved on that — never invent a memory.
    """
    let params = [ToolParam("query", "string", "Words to filter the saved memories by, matched case-insensitively. Omit to return everything saved.")]
    let statusLabel = "Recalling"
    let statusIcon = MemoryTools.icon
    let group = MemoryTools.group

    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        let query = JSON.string(args["query"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = MemoryStore.entries()
        guard !all.isEmpty else {
            return .ok(["ok": true, "count": 0, "lines": [],
                        "note": "Avo memory is empty. Tell the user nothing is saved yet; do not invent memories."])
        }
        let hits: [String]
        if let query, !query.isEmpty {
            hits = MemoryStore.matches(query)
        } else {
            // No filter: the whole file when it is short, otherwise the most recent lines.
            hits = all.count <= 40 ? all : Array(all.suffix(40))
        }
        guard !hits.isEmpty else {
            return .ok(["ok": true, "count": 0, "lines": [], "query": query ?? "",
                        "note": "Nothing saved matches that. Say so plainly; do not guess."])
        }
        var json: [String: Any] = ["ok": true, "count": hits.count, "lines": hits, "total": all.count]
        if let query, !query.isEmpty { json["query"] = query }
        if (query?.isEmpty ?? true), all.count > 40 { json["truncated"] = "showing the 40 most recent of \(all.count)" }
        let body = hits.prefix(8).map { $0.replacingOccurrences(of: "- ", with: "") }.joined(separator: "\n")
        return .ok(json, cards: [MemoryStore.card(header: "Memory", body: body)])
    }
}

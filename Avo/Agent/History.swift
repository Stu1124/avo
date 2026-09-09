import Foundation

/// Rolling on-disk history: every turn plus periodic session summaries.
@MainActor
final class History: ObservableObject {
    static let shared = History()
    struct Entry: Codable, Identifiable, Equatable { var id = UUID(); var role: String; var text: String; var at: Date; var chat: UUID? = nil }
    /// One conversation: consecutive turns that shared a model context.
    struct Chat: Identifiable, Equatable {
        let id: UUID
        var entries: [Entry]
        var title: String { entries.first { $0.role == "user" }?.text ?? "Chat" }
        var startedAt: Date { entries.first?.at ?? Date() }
        var lastAt: Date { entries.last?.at ?? Date() }
        var turnCount: Int { entries.filter { $0.role == "user" }.count }
        var exchanges: [(user: String, reply: String)] {
            var out: [(String, String)] = []
            for e in entries {
                if e.role == "user" { out.append((e.text, "")) }
                else if !out.isEmpty, out[out.count - 1].1.isEmpty { out[out.count - 1].1 = e.text }
            }
            return out
        }
    }
    struct Summary: Codable, Identifiable { var id = UUID(); var text: String; var at: Date }
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var summaries: [Summary] = []

    private init() { load() }

    var recentSummaries: [String] {
        let cutoff = Date().addingTimeInterval(-36 * 3600)
        return summaries.filter { $0.at > cutoff }.map { "- \($0.text)" }
    }

    /// Newest first. Entries written before chat ids existed are grouped by the same 90 s gap the
    /// runtime used to decide a request was a follow-up.
    func chats(limit: Int = 20) -> [Chat] {
        var out: [Chat] = []
        var index: [UUID: Int] = [:]
        var last: Entry?
        for e in entries {
            if let c = e.chat {
                if let i = index[c] { out[i].entries.append(e) }
                else { index[c] = out.count; out.append(Chat(id: c, entries: [e])) }
            } else {
                let sameChat = last.map { $0.chat == nil && (e.role == "assistant" || e.at.timeIntervalSince($0.at) < 90) } ?? false
                if sameChat, !out.isEmpty { out[out.count - 1].entries.append(e) }
                else { out.append(Chat(id: e.id, entries: [e])) }
            }
            last = e
        }
        return Array(out.filter { $0.turnCount > 0 }.suffix(limit).reversed())
    }

    func record(role: String, text: String, chat: UUID? = nil) {
        entries.append(.init(role: role, text: text, at: Date(), chat: chat))
        if entries.count > 2000 { entries.removeFirst(entries.count - 2000) }
        save()
    }

    func addSessionSummary(_ s: String) {
        summaries.append(.init(text: s, at: Date()))
        if summaries.count > 200 { summaries.removeFirst(summaries.count - 200) }
        save()
    }

    func clear() { entries = []; summaries = []; save() }

    /// Drops turns and summaries older than `days`. 0 means keep everything.
    /// Returns how many records went.
    @discardableResult
    func purge(olderThan days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let before = entries.count + summaries.count
        entries.removeAll { $0.at < cutoff }
        summaries.removeAll { $0.at < cutoff }
        let removed = before - (entries.count + summaries.count)
        if removed > 0 { save(); Log.info("History: purged \(removed) record(s) older than \(days) days") }
        return removed
    }

    private struct Disk: Codable { var entries: [Entry]; var summaries: [Summary] }
    private func load() {
        guard let d = try? Data(contentsOf: Paths.historyDB), let disk = try? JSONDecoder().decode(Disk.self, from: d) else { return }
        entries = disk.entries; summaries = disk.summaries
    }
    private func save() {
        try? FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(Disk(entries: entries, summaries: summaries)) { try? d.write(to: Paths.historyDB, options: .atomic) }
    }
}

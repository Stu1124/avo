import AppKit
import Foundation

/// Watches Gmail for NEW mail matching plain string filters; notifies once per match, no model involved.
struct EmailMonitorItem: Codable, Identifiable {
    var id: String
    var label: String
    var fromDomains: [String]
    var fromContains: [String]
    var subjectContains: [String]
    var createdAt: Date
    var status: String            // active, paused, cancelled
    var seenIds: [String]         // message ids already notified or present at creation
    var lastCheckedAt: Date?
    var matchCount: Int

    var isActive: Bool { status == "active" }
    var isListed: Bool { status == "active" || status == "paused" }

    /// Gmail query: recent mail narrowed by the sender filters; subject matched server-side too, then re-checked locally.
    var query: String {
        var parts = ["newer_than:1d"]
        let senders = fromDomains.map { "from:\($0)" } + fromContains.map { "from:\($0)" }
        if !senders.isEmpty { parts.append("(" + senders.joined(separator: " OR ") + ")") }
        if !subjectContains.isEmpty { parts.append("subject:(" + subjectContains.joined(separator: " OR ") + ")") }
        return parts.joined(separator: " ")
    }

    /// Local, case-insensitive re-check so Gmail's fuzzy matching never over-notifies.
    func matches(_ s: Gmail.Summary) -> Bool {
        let addr = s.fromAddress.lowercased(), name = s.fromName.lowercased(), subj = s.subject.lowercased()
        let domain = addr.split(separator: "@").last.map(String.init) ?? ""
        var senderOK = fromDomains.isEmpty && fromContains.isEmpty
        if !senderOK { senderOK = fromDomains.contains { domain == $0.lowercased() || domain.hasSuffix("." + $0.lowercased()) } }
        if !senderOK { senderOK = fromContains.contains { addr.contains($0.lowercased()) || name.contains($0.lowercased()) } }
        let subjectOK = subjectContains.isEmpty || subjectContains.contains { subj.contains($0.lowercased()) }
        return senderOK && subjectOK
    }

    var filterSummary: String {
        var bits: [String] = []
        if !fromDomains.isEmpty { bits.append("from " + fromDomains.joined(separator: ", ")) }
        if !fromContains.isEmpty { bits.append("from " + fromContains.joined(separator: ", ")) }
        if !subjectContains.isEmpty { bits.append("subject " + subjectContains.joined(separator: ", ")) }
        return bits.joined(separator: " · ")
    }

    func json() -> [String: Any] {
        var j: [String: Any] = ["id": id, "kind": "email_monitor", "source": "gmail", "label": label, "status": status,
                                "created": HDate.human(createdAt), "matches_so_far": matchCount, "checks_every": "2 min"]
        if !fromDomains.isEmpty { j["from_domains"] = fromDomains }
        if !fromContains.isEmpty { j["from_contains"] = fromContains }
        if !subjectContains.isEmpty { j["subject_contains"] = subjectContains }
        if let c = lastCheckedAt { j["last_checked"] = HDate.human(c) }
        return j
    }
}

@MainActor
final class EmailMonitorService {
    static let shared = EmailMonitorService()
    static let file = Paths.appSupport.appendingPathComponent("email-monitors.json")
    static let interval: TimeInterval = 120
    nonisolated static let icon = "envelope.badge.fill"

    private(set) var monitors: [EmailMonitorItem] = []
    private var timer: Timer?
    private var started = false
    private var polling = false
    private var cards: [String: UUID] = [:]      // message id → card id

    // MARK: lifecycle

    func start() {
        guard !started else { return }
        started = true
        load()
        Log.info("EmailMonitorService: \(monitors.count) stored, \(monitors.filter(\.isActive).count) active")
        armTimer()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.file) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        do { monitors = try dec.decode([EmailMonitorItem].self, from: data) }
        catch { Log.error("EmailMonitorService: could not decode email-monitors.json: \(error)") }
    }

    private func save() {
        monitors.removeAll { $0.status == "cancelled" }
        for i in monitors.indices where monitors[i].seenIds.count > 300 { monitors[i].seenIds = Array(monitors[i].seenIds.suffix(200)) }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
            try enc.encode(monitors).write(to: Self.file, options: .atomic)
        } catch { Log.error("EmailMonitorService: save failed: \(error)") }
    }

    // MARK: polling

    private func armTimer() {
        let want = monitors.contains(where: \.isActive)
        if want, timer == nil {
            let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in Task { @MainActor in await self?.poll() } }
            t.tolerance = 15; RunLoop.main.add(t, forMode: .common); timer = t
        } else if !want { timer?.invalidate(); timer = nil }
    }

    private func poll() async {
        guard !polling, GoogleAuth.shared.isConnected else { return }
        let active = monitors.filter(\.isActive)
        guard !active.isEmpty else { armTimer(); return }
        polling = true
        defer { polling = false }
        for m in active {
            do {
                let rows = try await Gmail.listSummaries(q: m.query, max: 10)
                guard let i = monitors.firstIndex(where: { $0.id == m.id }), monitors[i].isActive else { continue }
                monitors[i].lastCheckedAt = Date()
                let fresh = rows.filter { !m.seenIds.contains($0.id) && $0.date > m.createdAt && m.matches($0) }.sorted { $0.date < $1.date }
                monitors[i].seenIds.append(contentsOf: rows.map(\.id))
                monitors[i].matchCount += fresh.count
                for s in fresh { notify(monitors[i], s) }
            } catch {
                Log.warn("EmailMonitorService: '\(m.label)' check failed: \(error.localizedDescription)")
            }
        }
        save()
        armTimer()
    }

    private func notify(_ m: EmailMonitorItem, _ s: Gmail.Summary) {
        Log.info("EmailMonitorService: '\(m.label)' matched \(s.fromAddress) / \(s.subject.prefix(60))")
        let notch = NotchController.shared
        let cardId = UUID()
        cards[s.id] = cardId
        let from = s.fromName.isEmpty ? s.fromAddress : s.fromName
        var card = QuestionCard(id: cardId, icon: Gmail.icon, title: m.label,
                                body: "From: \(from)\nSubject: \(s.subject.isEmpty ? "(no subject)" : s.subject.preview(90))",
                                options: ["Open in Gmail", "Dismiss"], allowFreeText: false)
        card.onAnswer = { [weak self] answer in
            Task { @MainActor in
                if answer.hasPrefix("Open"), let u = URL(string: "https://mail.google.com/mail/u/0/#all/\(s.id)") { NSWorkspace.shared.open(u) }
                self?.dismiss(messageId: s.id)
            }
        }
        notch.present(.question(card), id: cardId)    // plays Sounds.card
    }

    private func dismiss(messageId: String) {
        guard let c = cards.removeValue(forKey: messageId) else { return }
        let notch = NotchController.shared
        notch.dismissCard(c)
        if notch.model.cards.isEmpty && notch.model.phase == .idle { notch.scheduleCollapse(after: 0.8) }
    }

    // MARK: API used by tools

    /// Creates the monitor and seeds `seenIds` with the current matches so existing mail never notifies.
    func create(label: String, fromDomains: [String], fromContains: [String], subjectContains: [String]) async -> EmailMonitorItem {
        var m = EmailMonitorItem(id: "mon-" + String(UUID().uuidString.prefix(6)).lowercased(), label: label,
                                 fromDomains: fromDomains.map { $0.lowercased().replacingOccurrences(of: "@", with: "") },
                                 fromContains: fromContains, subjectContains: subjectContains,
                                 createdAt: Date(), status: "active", seenIds: [], lastCheckedAt: nil, matchCount: 0)
        if let rows = try? await Gmail.listSummaries(q: m.query, max: 15) { m.seenIds = rows.map(\.id); m.lastCheckedAt = Date() }
        monitors.append(m)
        save()
        Log.info("EmailMonitorService: created '\(label)' [\(m.filterSummary)] seeded \(m.seenIds.count)")
        armTimer()
        return m
    }

    func find(_ id: String) -> EmailMonitorItem? { monitors.first { $0.id == id } }
    func listActive() -> [EmailMonitorItem] { monitors.filter(\.isListed).sorted { $0.createdAt > $1.createdAt } }

    func cancel(id: String) -> EmailMonitorItem? {
        guard let i = monitors.firstIndex(where: { $0.id == id }) else { return nil }
        var m = monitors[i]; m.status = "cancelled"
        monitors.remove(at: i)
        save(); armTimer()
        return m
    }

    func pause(id: String) -> EmailMonitorItem? {
        guard let i = monitors.firstIndex(where: { $0.id == id }) else { return nil }
        if monitors[i].status == "active" { monitors[i].status = "paused"; save(); armTimer() }
        return monitors[i]
    }

    func resume(id: String) -> EmailMonitorItem? {
        guard let i = monitors.firstIndex(where: { $0.id == id }) else { return nil }
        if monitors[i].status == "paused" { monitors[i].status = "active"; save(); armTimer() }
        return monitors[i]
    }
}

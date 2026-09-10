import AppKit
import Foundation

/// A thread Avo sent into, watched for the first incoming reply. Created automatically after send_message / gmail_send / gmail_reply.
struct ReplyWatchItem: Codable, Identifiable {
    var id: String
    var kind: String              // imessage, gmail
    var target: String            // chat guid or Gmail thread id
    var label: String             // "TJ", "bob@acme.com"
    var handle: String?           // iMessage: a participant handle for the Open button
    var chatRowId: Int64?         // iMessage: resolved lazily
    var sentAt: Date
    var expiresAt: Date
    var status: String            // watching, paused, replied, expired, cancelled
    var repliedAt: Date?
    var replyPreview: String?

    var isActive: Bool { status == "watching" }
    var isListed: Bool { status == "watching" || status == "paused" }
    var icon: String { kind == "imessage" ? MessagesStore.icon : Gmail.icon }

    func json() -> [String: Any] {
        var j: [String: Any] = ["id": id, "kind": "reply_watch", "channel": kind == "imessage" ? "iMessage" : "Gmail", "watching": label,
                                "sent_at": HDate.human(sentAt), "expires": HDate.human(expiresAt), "status": status]
        if let r = repliedAt { j["replied_at"] = HDate.human(r) }
        if let p = replyPreview { j["reply"] = p }
        return j
    }
}

/// Watches sent threads for a reply and notifies once. iMessage polls chat.db every 30 s, Gmail every 2 min; no timers when idle.
@MainActor
final class ReplyWatch {
    static let shared = ReplyWatch()
    static let file = Paths.appSupport.appendingPathComponent("reply-watches.json")
    static let ttl: TimeInterval = 3 * 86400
    static let imessageInterval: TimeInterval = 30
    static let gmailInterval: TimeInterval = 120

    enum Kind: Sendable {
        case imessage(chatGuid: String)
        case gmail(threadId: String)
    }

    private(set) var watches: [ReplyWatchItem] = []
    private var imessageTimer: Timer?
    private var gmailTimer: Timer?
    private var cards: [String: UUID] = [:]
    private var started = false
    private var pollingIMessage = false
    private var pollingGmail = false

    // MARK: lifecycle

    func start() {
        guard !started else { return }
        started = true
        load()
        expireStale()
        Log.info("ReplyWatch: \(watches.count) stored, \(watches.filter(\.isActive).count) active")
        armTimers()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.file) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        do { watches = try dec.decode([ReplyWatchItem].self, from: data) }
        catch { Log.error("ReplyWatch: could not decode reply-watches.json: \(error)") }
    }

    private func save() {
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        watches.removeAll { !$0.isListed && ($0.repliedAt ?? $0.expiresAt) < cutoff }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
            try enc.encode(watches).write(to: Self.file, options: .atomic)
        } catch { Log.error("ReplyWatch: save failed: \(error)") }
    }

    // MARK: hook called by the send tools (any thread)

    /// Auto-creates a watch after a successful send. `fallbackHandle` lets iMessage sends without a chat guid resolve the chat later.
    nonisolated func noteSent(kind: Kind, label: String, fallbackHandle: String? = nil) {
        Task { @MainActor in self.add(kind: kind, label: label, fallbackHandle: fallbackHandle) }
    }

    private func add(kind: Kind, label: String, fallbackHandle: String?) {
        let k: String, target: String
        switch kind {
        case .imessage(let g): k = "imessage"; target = g
        case .gmail(let t): k = "gmail"; target = t
        }
        if target.isEmpty && fallbackHandle == nil { return }
        // One watch per thread: a new send restarts the clock.
        watches.removeAll { $0.isListed && $0.kind == k && $0.target == target && !target.isEmpty }
        let w = ReplyWatchItem(id: "rw-" + String(UUID().uuidString.prefix(6)).lowercased(), kind: k, target: target, label: label,
                               handle: fallbackHandle, chatRowId: nil, sentAt: Date(), expiresAt: Date().addingTimeInterval(Self.ttl),
                               status: "watching", repliedAt: nil, replyPreview: nil)
        watches.append(w)
        save()
        Log.info("ReplyWatch: watching \(k) '\(label)' (\(w.id))")
        armTimers()
    }

    // MARK: polling

    private func armTimers() {
        let active = watches.filter(\.isActive)
        let wantIM = active.contains { $0.kind == "imessage" }
        let wantGmail = active.contains { $0.kind == "gmail" }
        if wantIM, imessageTimer == nil {
            let t = Timer(timeInterval: Self.imessageInterval, repeats: true) { [weak self] _ in Task { @MainActor in self?.pollIMessage() } }
            t.tolerance = 5; RunLoop.main.add(t, forMode: .common); imessageTimer = t
        } else if !wantIM { imessageTimer?.invalidate(); imessageTimer = nil }
        if wantGmail, gmailTimer == nil {
            let t = Timer(timeInterval: Self.gmailInterval, repeats: true) { [weak self] _ in Task { @MainActor in self?.pollGmail() } }
            t.tolerance = 15; RunLoop.main.add(t, forMode: .common); gmailTimer = t
        } else if !wantGmail { gmailTimer?.invalidate(); gmailTimer = nil }
    }

    private func expireStale() {
        let now = Date()
        var changed = false
        for i in watches.indices where watches[i].isListed && watches[i].expiresAt < now {
            watches[i].status = "expired"; changed = true
        }
        if changed { save() }
    }

    private func pollIMessage() {
        guard !pollingIMessage else { return }
        expireStale()
        let targets = watches.filter { $0.isActive && $0.kind == "imessage" }
        guard !targets.isEmpty else { armTimers(); return }
        // Nothing to poll until Full Disk Access is granted. The timer stays armed so the first poll
        // after the grant picks the watches up, and the skip itself is silent.
        guard MessagesStore.accessGranted() else { return }
        pollingIMessage = true
        Task.detached(priority: .utility) { [targets] in
            var found: [(String, Int64?, String, String)] = []   // watch id, chat row, sender name, text
            let store = MessagesStore.shared
            for w in targets {
                var rowId = w.chatRowId
                if rowId == nil, let chat = try? store.findChat(guid: w.target.isEmpty ? nil : w.target, recipient: w.handle) { rowId = chat.rowId }
                guard let rowId else { continue }
                guard let msgs = try? store.messages(chatId: rowId, limit: 8) else { continue }
                if let reply = msgs.last(where: { !$0.fromMe && $0.date > w.sentAt.addingTimeInterval(1) }) {
                    found.append((w.id, rowId, reply.senderName, reply.text))
                } else if w.chatRowId == nil {
                    found.append((w.id, rowId, "", ""))    // just cache the row id
                }
            }
            await MainActor.run { [found] in
                for (id, rowId, sender, text) in found {
                    guard let i = self.watches.firstIndex(where: { $0.id == id }) else { continue }
                    self.watches[i].chatRowId = rowId
                    if !text.isEmpty || !sender.isEmpty { self.replied(id: id, sender: sender, preview: text) }
                }
                self.pollingIMessage = false
                self.save()
                self.armTimers()
            }
        }
    }

    private func pollGmail() {
        guard !pollingGmail else { return }
        expireStale()
        let targets = watches.filter { $0.isActive && $0.kind == "gmail" }
        guard !targets.isEmpty else { armTimers(); return }
        guard GoogleAuth.shared.isConnected else { return }
        pollingGmail = true
        let me = (GoogleAuth.shared.email ?? "").lowercased()
        Task { [targets] in
            for w in targets {
                do {
                    let t = try await GoogleAPI.json(.GET, "\(Gmail.base)/threads/\(w.target)", query: ["format": "metadata", "metadataHeaders": ["From"]])
                    let msgs = t["messages"] as? [[String: Any]] ?? []
                    for m in msgs {
                        let from = Gmail.parseAddress(Gmail.header(m, "From") ?? "")
                        guard !from.address.isEmpty, from.address.lowercased() != me else { continue }
                        guard Gmail.date(m) > w.sentAt.addingTimeInterval(1) else { continue }
                        let snippet = Gmail.decodeEntities(m["snippet"] as? String ?? "")
                        replied(id: w.id, sender: from.name.isEmpty ? from.address : from.name, preview: snippet)
                        break
                    }
                } catch {
                    Log.warn("ReplyWatch: Gmail thread \(w.target) check failed: \(error.localizedDescription)")
                }
            }
            pollingGmail = false
            armTimers()
        }
    }

    // MARK: reply handling

    private func replied(id: String, sender: String, preview: String) {
        guard let i = watches.firstIndex(where: { $0.id == id }), watches[i].isActive else { return }
        watches[i].status = "replied"
        watches[i].repliedAt = Date()
        watches[i].replyPreview = preview.preview(140)
        save()
        let w = watches[i]
        Log.info("ReplyWatch: reply from '\(w.label)' (\(w.id))")
        let notch = NotchController.shared
        let cardId = UUID()
        cards[id] = cardId
        let who = w.kind == "imessage" && !sender.isEmpty && sender != w.label ? "\(w.label) · \(sender)" : w.label
        var card = QuestionCard(id: cardId, icon: w.icon, title: "\(who) replied", body: w.replyPreview ?? "",
                                options: [w.kind == "imessage" ? "Open Messages" : "Open Gmail", "Dismiss"], allowFreeText: false)
        card.onAnswer = { [weak self] answer in Task { @MainActor in self?.handle(answer, watchId: id) } }
        notch.present(.question(card), id: cardId)    // plays Sounds.card
        armTimers()
    }

    private func handle(_ answer: String, watchId: String) {
        if answer.hasPrefix("Open"), let w = watches.first(where: { $0.id == watchId }) { open(w) }
        if let c = cards.removeValue(forKey: watchId) {
            let notch = NotchController.shared
            notch.dismissCard(c)
            if notch.model.cards.isEmpty && notch.model.phase == .idle { notch.scheduleCollapse(after: 0.8) }
        }
    }

    private func open(_ w: ReplyWatchItem) {
        if w.kind == "gmail" {
            if let u = URL(string: "https://mail.google.com/mail/u/0/#all/\(w.target)") { NSWorkspace.shared.open(u) }
            return
        }
        // 1:1 chats deep-link by handle; groups just bring Messages forward.
        if let h = w.handle ?? Self.singleHandle(w), let u = URL(string: "imessage://" + (h.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? h)) {
            NSWorkspace.shared.open(u); return
        }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func singleHandle(_ w: ReplyWatchItem) -> String? {
        guard !w.target.isEmpty, let chat = try? MessagesStore.shared.findChat(guid: w.target, recipient: nil), !chat.isGroup else { return nil }
        return chat.participants.first ?? (chat.identifier.isEmpty ? nil : chat.identifier)
    }

    // MARK: API used by tools


    /// Watching and paused, newest first.
    func listActive() -> [ReplyWatchItem] { watches.filter(\.isListed).sorted { $0.sentAt > $1.sentAt } }

    func cancel(id: String) -> ReplyWatchItem? {
        guard let i = watches.firstIndex(where: { $0.id == id }) else { return nil }
        if watches[i].isListed { watches[i].status = "cancelled"; save(); armTimers() }
        return watches[i]
    }

    func pause(id: String) -> ReplyWatchItem? {
        guard let i = watches.firstIndex(where: { $0.id == id }) else { return nil }
        if watches[i].status == "watching" { watches[i].status = "paused"; save(); armTimers() }
        return watches[i]
    }

    func resume(id: String) -> ReplyWatchItem? {
        guard let i = watches.firstIndex(where: { $0.id == id }) else { return nil }
        if watches[i].status == "paused" { watches[i].status = "watching"; save(); armTimers() }
        return watches[i]
    }
}

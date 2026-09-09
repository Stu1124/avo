import AppKit
import Foundation

/// A real tool call frozen for later: approved once at creation, replayed verbatim at `performAt` with no model involved.
/// Persisted as JSON in ~/Library/Application Support/Avo/scheduled.json.
struct ScheduledAction: Codable, Identifiable {
    var id: String
    var title: String
    var innerTool: String
    var argumentsJSON: String          // frozen tool_arguments (JSON object)
    var performAt: Date
    var status: String                 // scheduled, running, done, failed, missed, cancelled
    var createdAt: Date
    var ranAt: Date?
    var error: String?

    static let innerTools = ["send_message", "gmail_send", "gmail_reply", "gcal_create_event", "create_reminder"]

    var isPending: Bool { status == "scheduled" }
    var arguments: [String: Any] { JSON.parse(argumentsJSON) }

    /// Icon for cards, by inner tool.
    var icon: String {
        switch innerTool {
        case "send_message": return MessagesStore.icon
        case "gmail_send", "gmail_reply": return Gmail.icon
        case "gcal_create_event": return "calendar.badge.plus"
        case "create_reminder": return "app:com.apple.reminders"
        default: return "clock.badge.checkmark"
        }
    }

    /// Who/what the action targets: "TJ", "bob@acme.com", the event title.
    var target: String {
        let a = arguments
        switch innerTool {
        case "send_message": return a.str("to") ?? a.str("recipient") ?? "chat"
        case "gmail_send": return GoogleAPI.strings(a["to"]).first ?? "?"
        case "gmail_reply": return a.str("to") ?? "the original sender"
        case "gcal_create_event": return a.str("title") ?? "event"
        case "create_reminder": return a.str("title") ?? "reminder"
        default: return innerTool
        }
    }

    /// Past-tense outcome line for the fire card, e.g. "Sent to TJ".
    var doneLine: String {
        switch innerTool {
        case "send_message", "gmail_send": return "Sent to \(target)"
        case "gmail_reply": return "Replied to \(target)"
        case "gcal_create_event": return "Created \(target)"
        case "create_reminder": return "Added \(target)"
        default: return "Ran \(innerTool)"
        }
    }

    /// The key fields a person cares about, in display order (≤4 pairs).
    var keyPairs: [(String, String)] {
        let a = arguments
        var out: [(String, String)] = []
        func add(_ label: String, _ key: String, preview n: Int = 120) {
            if let v = a[key] {
                let s = (JSON.string(v) ?? GoogleAPI.strings(v).joined(separator: ", ")).preview(n)
                if !s.isEmpty { out.append((label, s)) }
            }
        }
        switch innerTool {
        case "send_message": add("To", "to"); if out.isEmpty { add("To", "recipient") }; add("Message", "message")
        case "gmail_send": add("To", "to"); add("Subject", "subject"); add("Body", "body")
        case "gmail_reply": add("To", "to"); add("Reply", "body")
        case "gcal_create_event": add("Title", "title"); add("Start", "start_datetime"); add("Attendees", "attendees")
        case "create_reminder": add("Title", "title"); add("Due", "due"); add("List", "list")
        default: break
        }
        return Array(out.prefix(4))
    }

    /// Short one-line summary: "to TJ: hey are we still on…".
    var summary: String {
        let a = arguments
        switch innerTool {
        case "send_message": return "to \(target): \((a.str("message") ?? "").preview(60))"
        case "gmail_send": return "to \(target): \((a.str("subject") ?? "").preview(50))"
        case "gmail_reply": return "reply to \(target)"
        case "gcal_create_event": return "\(target)\(a.str("start_datetime").map { " at \($0)" } ?? "")"
        case "create_reminder": return target
        default: return innerTool
        }
    }

    func json() -> [String: Any] {
        var j: [String: Any] = ["id": id, "kind": "scheduled_action", "title": title, "inner_tool": innerTool, "tool_arguments": arguments,
                                "performs_at": HDate.human(performAt), "performs_at_iso": HDate.iso(performAt), "status": status]
        if isPending { j["in"] = HDate.countdown(to: performAt) }
        if let r = ranAt { j["ran_at"] = HDate.human(r) }
        if let e = error { j["error"] = e }
        return j
    }
}

/// Runs frozen tool calls at their time, survives relaunch, one next-fire timer (same shape as LocalReminderScheduler).
@MainActor
final class ScheduledActionStore {
    static let shared = ScheduledActionStore()
    static let file = Paths.appSupport.appendingPathComponent("scheduled.json")
    nonisolated static let icon = "clock.badge.checkmark"
    /// An action Avo missed by more than this does not run; the user is told instead.
    static let maxOverdue: TimeInterval = 3600

    private(set) var actions: [ScheduledAction] = []
    private var timer: Timer?
    private var started = false
    private var wakeObserver: Any?

    // MARK: lifecycle

    func start() {
        guard !started else { return }
        started = true
        load()
        Log.info("ScheduledActionStore: \(actions.count) stored, \(actions.filter(\.isPending).count) pending")
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Anything stuck in "running" from a crash mid-fire is unknowable: mark failed rather than re-send.
        for i in actions.indices where actions[i].status == "running" {
            actions[i].status = "failed"; actions[i].error = "Avo quit while this was running; it may or may not have completed."
        }
        // Overdue actions run shortly after launch (registry must be populated first).
        if actions.contains(where: \.isPending) {
            let t = Timer(timeInterval: 5, repeats: false) { [weak self] _ in Task { @MainActor in self?.tick() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.file) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        do { actions = try dec.decode([ScheduledAction].self, from: data) }
        catch { Log.error("ScheduledActionStore: could not decode scheduled.json: \(error)") }
    }

    private func save() {
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        actions.removeAll { !$0.isPending && $0.status != "running" && ($0.ranAt ?? $0.performAt) < cutoff }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
            try enc.encode(actions).write(to: Self.file, options: .atomic)
        } catch { Log.error("ScheduledActionStore: save failed: \(error)") }
    }

    // MARK: scheduling

    private func tick() {
        let now = Date()
        for a in actions where a.isPending && a.performAt <= now.addingTimeInterval(0.5) {
            fire(a, overdueBy: now.timeIntervalSince(a.performAt))
        }
        armTimer()
    }

    private func armTimer() {
        timer?.invalidate(); timer = nil
        guard let next = actions.filter(\.isPending).map(\.performAt).min() else { return }
        let delay = max(next.timeIntervalSinceNow, 0.2)
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in Task { @MainActor in self?.tick() } }
        t.tolerance = min(2, delay * 0.05)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.info("ScheduledActionStore: next fire \(HDate.human(next)) (\(HDate.countdown(to: next)))")
    }

    private func fire(_ a: ScheduledAction, overdueBy: TimeInterval) {
        guard let i = actions.firstIndex(where: { $0.id == a.id }) else { return }
        if overdueBy > Self.maxOverdue {
            actions[i].status = "missed"
            actions[i].error = "Avo was not running at \(HDate.human(a.performAt)); the action did NOT run."
            save()
            Log.warn("ScheduledActionStore: missed '\(a.title)' (\(Int(overdueBy / 60)) min late)")
            present(Cards.note(source: "Avo", icon: "exclamationmark.triangle.fill", title: "Did not run: \(a.title)",
                               body: "Avo was off at \(HDate.human(a.performAt)). Schedule it again if it still matters."), sound: .error)
            return
        }
        actions[i].status = "running"
        save()
        Log.info("ScheduledActionStore: firing '\(a.title)' → \(a.innerTool)\(overdueBy > 90 ? " (overdue)" : "")")
        Task { @MainActor in await self.perform(a.id) }
    }

    private func perform(_ id: String) async {
        guard let a = actions.first(where: { $0.id == id }) else { return }
        let notch = NotchController.shared
        let chip = notch.status(a.doneLine.hasPrefix("Sent") || a.doneLine.hasPrefix("Replied") ? "Sending (scheduled)" : "Running (scheduled)", icon: a.icon)
        var result: ToolResult
        if let tool = ToolRegistry.shared.tool(a.innerTool) {
            let args = a.arguments
            let ctx = ToolContext(turnId: UUID(), screenshotPath: nil, selectedText: nil, frontmostApp: nil, frontmostBundleId: nil,
                                  clipboard: nil, openCardTaskId: nil, attachments: [], transcript: a.title)
            do { result = try await withTimeout(seconds: 90) { await tool.run(args, ctx: ctx) } }
            catch { result = .fail("\(a.innerTool) timed out.") }
        } else {
            result = .fail("Tool \(a.innerTool) is not available (integration disabled?).")
        }
        notch.finishStatus(chip, ok: result.ok)
        guard let i = actions.firstIndex(where: { $0.id == id }) else { return }
        actions[i].ranAt = Date()
        if result.ok {
            actions[i].status = "done"; actions[i].error = nil
            save()
            Log.info("ScheduledActionStore: done '\(a.title)'")
            let sub = a.keyPairs.first { ["Message", "Body", "Reply", "Subject", "Start", "Due"].contains($0.0) }?.1 ?? a.title
            present(Cards.glance(source: "Avo", icon: a.icon, header: ("\(a.doneLine) (scheduled)", sub.preview(100))), sound: .done)
        } else {
            let err = (result.json["error"] as? String) ?? "Unknown error"
            actions[i].status = "failed"; actions[i].error = err
            save()
            Log.error("ScheduledActionStore: failed '\(a.title)': \(err)")
            present(Cards.note(source: "Avo", icon: "exclamationmark.triangle.fill", title: "Scheduled action failed: \(a.title)", body: err.preview(160)), sound: .error)
        }
    }

    private func present(_ card: CardKind, sound: Sounds.Cue) {
        let notch = NotchController.shared
        notch.present(card)
        Sounds.shared.play(sound)
        if notch.model.phase == .idle { notch.scheduleCollapse(after: 20) }
    }

    // MARK: API used by tools

    @discardableResult
    func create(title: String, innerTool: String, arguments: [String: Any], performAt: Date) -> ScheduledAction {
        let a = ScheduledAction(id: "act-" + String(UUID().uuidString.prefix(6)).lowercased(), title: title, innerTool: innerTool,
                                argumentsJSON: JSON.stringify(arguments), performAt: performAt, status: "scheduled", createdAt: Date(), ranAt: nil, error: nil)
        actions.append(a)
        save()
        Log.info("ScheduledActionStore: created '\(title)' → \(innerTool) at \(HDate.human(performAt))")
        armTimer()
        return a
    }

    func cancel(id: String) -> ScheduledAction? {
        guard let i = actions.firstIndex(where: { $0.id == id }) else { return nil }
        guard actions[i].isPending else { return actions[i] }
        actions[i].status = "cancelled"
        save()
        armTimer()
        return actions[i]
    }

    func find(_ id: String) -> ScheduledAction? { actions.first { $0.id == id } }

    /// Pending first (soonest first), then recently finished/failed.
    func listActive() -> [ScheduledAction] {
        let pending = actions.filter(\.isPending).sorted { $0.performAt < $1.performAt }
        let recent = actions.filter { !$0.isPending && $0.status != "cancelled" && ($0.ranAt ?? $0.performAt).timeIntervalSinceNow > -86400 }
        return pending + recent
    }
}

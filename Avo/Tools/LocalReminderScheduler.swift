import AppKit
import CoreGraphics
import Foundation
import UserNotifications

/// A reminder that fires on this Mac at a time, no model involved. Persisted as JSON in Paths.remindersDB.
struct LocalReminder: Codable, Identifiable {
    var id: String
    var message: String
    var url: String?
    var fireAt: Date
    var repeatRule: String      // none, daily, weekdays, weekly
    var status: String          // scheduled, fired, done, cancelled
    var createdAt: Date
    var lastFiredAt: Date?

    var isPending: Bool { status == "scheduled" }
    var repeats: Bool { repeatRule != "none" }

    func json() -> [String: Any] {
        var j: [String: Any] = ["id": id, "message": message, "fires_at": HDate.human(fireAt), "fires_at_iso": HDate.iso(fireAt),
                                "repeat": repeatRule, "status": status]
        if status == "scheduled" { j["in"] = HDate.countdown(to: fireAt) }
        if let u = url { j["url"] = u }
        return j
    }
}

/// Schedules local reminders, survives relaunch, shows a ReminderCard in the notch when one fires.
@MainActor
final class LocalReminderScheduler {
    static let shared = LocalReminderScheduler()
    nonisolated static let validRepeats = ["none", "daily", "weekdays", "weekly"]

    private(set) var reminders: [LocalReminder] = []
    private var timer: Timer?
    private var cards: [String: UUID] = [:]           // reminder id → card id
    private(set) var activeReminderId: String?        // most recently fired card still on screen
    private var started = false
    private var wakeObserver: Any?
    private var notificationsAuthorized = false

    // MARK: lifecycle

    func start() {
        guard !started else { return }
        started = true
        load()
        let pending = reminders.filter(\.isPending)
        Log.info("LocalReminderScheduler: \(reminders.count) stored, \(pending.count) pending")
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.remindersDB) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        do { reminders = try dec.decode([LocalReminder].self, from: data) }
        catch { Log.error("LocalReminderScheduler: could not decode reminders.json: \(error)") }
    }

    private func save() {
        // Keep the file small: drop finished one-shots older than a week.
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        reminders.removeAll { ($0.status == "done" || $0.status == "cancelled") && ($0.lastFiredAt ?? $0.createdAt) < cutoff }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
            try enc.encode(reminders).write(to: Paths.remindersDB, options: .atomic)
        } catch { Log.error("LocalReminderScheduler: save failed: \(error)") }
    }

    // MARK: scheduling

    private func tick() {
        let now = Date()
        for r in reminders where r.isPending && r.fireAt <= now.addingTimeInterval(0.5) {
            fire(r, overdue: now.timeIntervalSince(r.fireAt) > 90)
        }
        armTimer()
    }

    private func armTimer() {
        timer?.invalidate(); timer = nil
        guard let next = reminders.filter(\.isPending).map(\.fireAt).min() else { return }
        let delay = max(next.timeIntervalSinceNow, 0.2)
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in Task { @MainActor in self?.tick() } }
        t.tolerance = min(2, delay * 0.05)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.info("LocalReminderScheduler: next fire \(HDate.human(next)) (\(HDate.countdown(to: next)))")
    }

    private func fire(_ r: LocalReminder, overdue: Bool) {
        guard let i = reminders.firstIndex(where: { $0.id == r.id }) else { return }
        let scheduledFor = r.fireAt
        reminders[i].lastFiredAt = Date()
        if r.repeats, let next = Self.nextOccurrence(after: Date(), from: r.fireAt, rule: r.repeatRule) {
            reminders[i].fireAt = next
        } else {
            reminders[i].status = "fired"
        }
        save()
        Log.info("LocalReminderScheduler: fired '\(r.message)'\(overdue ? " (overdue)" : "")")
        presentCard(reminders[i], scheduledFor: scheduledFor, overdue: overdue)
        if screenLocked { postSystemNotification(reminders[i]) }
    }

    private func presentCard(_ r: LocalReminder, scheduledFor: Date, overdue: Bool) {
        let notch = NotchController.shared
        if let old = cards[r.id] { notch.dismissCard(old) }
        let cardId = UUID()
        cards[r.id] = cardId
        activeReminderId = r.id
        var card = ReminderCard(id: cardId, reminderId: r.id, message: overdue ? "Overdue: \(r.message)" : r.message, url: r.url, fireAt: scheduledFor)
        card.onAction = { [weak self] action in Task { @MainActor in self?.handle(action, reminderId: r.id) } }
        Sounds.shared.play(.card)
        notch.reveal()
        notch.present(.reminder(card), id: cardId)
    }

    private func handle(_ action: String, reminderId: String) {
        Log.info("LocalReminderScheduler: action '\(action)' on \(reminderId)")
        switch action {
        case "open":
            if let u = reminders.first(where: { $0.id == reminderId })?.url, let url = URL(string: u) { NSWorkspace.shared.open(url) }
            _ = dismiss(id: reminderId)
        case "done":
            _ = dismiss(id: reminderId)
        case "snooze:tomorrow":
            _ = snooze(id: reminderId, until: Self.tomorrowMorning())
        default:
            if action.hasPrefix("snooze:"), let m = Int(action.dropFirst(7)) { _ = snooze(id: reminderId, minutes: m) }
            else { _ = dismiss(id: reminderId) }
        }
    }

    private func removeCard(_ id: String) {
        if let c = cards.removeValue(forKey: id) {
            let notch = NotchController.shared
            notch.dismissCard(c)
            if notch.model.cards.isEmpty && notch.model.phase == .idle { notch.scheduleCollapse(after: 0.8) }
        }
        if activeReminderId == id { activeReminderId = cards.keys.first }
    }

    // MARK: API used by tools

    @discardableResult
    func create(message: String, fireAt: Date, repeatRule: String, url: String?) -> LocalReminder {
        let r = LocalReminder(id: String(UUID().uuidString.prefix(8)).lowercased(), message: message, url: url, fireAt: fireAt,
                              repeatRule: Self.validRepeats.contains(repeatRule) ? repeatRule : "none", status: "scheduled", createdAt: Date(), lastFiredAt: nil)
        reminders.append(r)
        save()
        Log.info("LocalReminderScheduler: created '\(message)' at \(HDate.human(fireAt)) repeat=\(r.repeatRule)")
        armTimer()
        return r
    }

    func update(id: String, message: String?, fireAt: Date?, repeatRule: String?, url: String?) -> LocalReminder? {
        guard let i = reminders.firstIndex(where: { $0.id == id }) else { return nil }
        if let m = message { reminders[i].message = m }
        if let f = fireAt { reminders[i].fireAt = f; reminders[i].status = "scheduled" }
        if let rr = repeatRule, Self.validRepeats.contains(rr) { reminders[i].repeatRule = rr }
        if let u = url { reminders[i].url = u.isEmpty ? nil : u }
        if reminders[i].status == "cancelled" || reminders[i].status == "done" { reminders[i].status = "scheduled" }
        save()
        removeCard(id)
        armTimer()
        return reminders[i]
    }

    func cancel(id: String) -> LocalReminder? {
        guard let i = reminders.firstIndex(where: { $0.id == id }) else { return nil }
        reminders[i].status = "cancelled"
        save()
        removeCard(id)
        armTimer()
        return reminders[i]
    }

    /// Snooze a fired (or pending) reminder. Repeating reminders spawn a one-shot copy so their cadence is untouched.
    func snooze(id: String?, minutes: Int) -> LocalReminder? {
        snooze(id: id, until: Date().addingTimeInterval(Double(max(minutes, 1)) * 60))
    }

    func snooze(id: String?, until: Date) -> LocalReminder? {
        guard let rid = id ?? activeReminderId, let i = reminders.firstIndex(where: { $0.id == rid }) else { return nil }
        let r = reminders[i]
        removeCard(rid)
        if r.repeats {
            return create(message: r.message, fireAt: until, repeatRule: "none", url: r.url)
        }
        reminders[i].fireAt = until
        reminders[i].status = "scheduled"
        save()
        Log.info("LocalReminderScheduler: snoozed '\(r.message)' to \(HDate.human(until))")
        armTimer()
        return reminders[i]
    }

    func dismiss(id: String?) -> LocalReminder? {
        guard let rid = id ?? activeReminderId, let i = reminders.firstIndex(where: { $0.id == rid }) else { return nil }
        if !reminders[i].repeats { reminders[i].status = "done" }
        save()
        removeCard(rid)
        return reminders[i]
    }

    func find(_ id: String) -> LocalReminder? { reminders.first { $0.id == id } }

    /// Scheduled and fired-but-unhandled reminders, soonest first.
    func listActive() -> [LocalReminder] {
        reminders.filter { $0.status == "scheduled" || $0.status == "fired" }.sorted { $0.fireAt < $1.fireAt }
    }

    // MARK: helpers

    static func nextOccurrence(after now: Date, from base: Date, rule: String) -> Date? {
        let cal = Calendar.current
        var d = base
        var guardCount = 0
        while d <= now && guardCount < 400 {
            switch rule {
            case "daily": d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
            case "weekly": d = cal.date(byAdding: .day, value: 7, to: d) ?? d.addingTimeInterval(7 * 86400)
            case "weekdays":
                d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
                while [1, 7].contains(cal.component(.weekday, from: d)) { d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400) }
            default: return nil
            }
            guardCount += 1
        }
        return d
    }

    static func tomorrowMorning() -> Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date().addingTimeInterval(86400)
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private var screenLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let b = d["CGSSessionScreenIsLocked"] as? Bool { return b }
        if let n = d["CGSSessionScreenIsLocked"] as? NSNumber { return n.boolValue }
        return false
    }

    private func postSystemNotification(_ r: LocalReminder) {
        let center = UNUserNotificationCenter.current()
        let deliver = {
            let c = UNMutableNotificationContent()
            c.title = "Avo reminder"
            c.body = r.message
            c.sound = .default
            center.add(UNNotificationRequest(identifier: "avo-reminder-\(r.id)", content: c, trigger: nil)) { err in
                if let err { Log.warn("UNUserNotification failed: \(err.localizedDescription)") }
            }
        }
        if notificationsAuthorized { deliver(); return }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] ok, _ in
            Task { @MainActor in self?.notificationsAuthorized = ok }
            if ok { deliver() }
        }
    }
}

// MARK: - Tools

enum LocalReminderTools {
    static let group = "Reminders"
    static let icon = "bell.badge.fill"

    static func all() -> [Tool] {
        [Create(), Update(), ListScheduled(), Cancel(), Snooze(), Dismiss()]
    }

    struct ArgError: Error, CustomStringConvertible { let message: String; var description: String { message } }

    /// Resolve delay_minutes / fire_at_iso from args. Returns nil when neither is given.
    static func fireDate(_ args: [String: Any]) -> Result<Date?, ArgError> {
        if let m = args.double("delay_minutes") {
            guard m > 0 else { return .failure(ArgError(message: "delay_minutes must be positive")) }
            return .success(Date().addingTimeInterval(m * 60))
        }
        if let s = args.str("fire_at_iso") {
            guard let d = HDate.parse(s) else { return .failure(ArgError(message: "Could not parse fire_at_iso '\(s)'. Use ISO-8601 with an offset, e.g. 2026-07-18T17:00:00-07:00.")) }
            return .success(d)
        }
        return .success(nil)
    }

    static func card(_ r: LocalReminder, title: String) -> CardKind {
        var sub = "\(HDate.human(r.fireAt)) · \(HDate.countdown(to: r.fireAt))"
        if r.repeats { sub += " · \(r.repeatRule)" }
        return .glance(GlanceCard(id: UUID(), blocks: [.header(title: title, subtitle: sub, icon: icon), .text(r.message)], source: "Avo", sourceIcon: icon))
    }

    struct Create: Tool {
        let name = "avo_create_reminder"
        let description = "Sets an alarm that goes off on this Mac at a chosen moment; it needs no network and no second trip through the model. Treat it as the DEFAULT answer to EVERY timed 'remind me' — 'remind me in 10 minutes', 'every weekday at 9 remind me to check email', 'at 5, remind me to call mom' — and call it straight away. One EXCEPTION breaks that rule: when your context already holds an ACTIVE NOTIFICATION CARD reminder and the user is pushing THAT very card further out ('not now, later', 'push it back', '...instead', 'remind me in an hour'), they are snoozing, so avo_snooze_notification is the tool, NOT this one. Making a new reminder leaves the old card untouched, which means it returns and you end up with two alarms. Timed requests must NEVER be routed to the Apple Reminders tools such as create_reminder — those exist only for deliberate work inside that app's lists: 'check off my groceries list', or 'add milk to my Reminders app'. Express relative times through delay_minutes, and absolute ones through fire_at_iso in complete ISO-8601 WITH the user's timezone offset; work out something like 'at 5 PM' from the local time in your context, rolling to tomorrow when today's has gone by. Repetition is optional and limited to daily, weekdays, or weekly, the last landing on whatever weekday fire_at falls on. Richer patterns — monthly, every second Tuesday — are NOT supported, so tell the user rather than scheduling one."
        let params = [
            ToolParam("message", "string", "The reminder's wording, kept close to how the user put it — 'Call mom', for instance. It both appears on the card and gets read out.", required: true),
            ToolParam("delay_minutes", "number", "A count of minutes ahead of the present moment; 'in 10 minutes' becomes 10. Supply either this field or fire_at_iso, not both."),
            ToolParam("fire_at_iso", "string", "A fixed point in time written in ISO-8601 that includes the timezone offset — '2026-07-18T17:00:00-07:00' is the pattern. An offsetless timestamp is never acceptable here."),
            ToolParam("repeat", "string", "How often it recurs. Choosing 'weekly' means it returns on whichever weekday it first went off. Nothing repeats unless this is set.", enumValues: ["none", "daily", "weekdays", "weekly"]),
            ToolParam("url", "string", "Optional. An address to attach — a call's join link, a document — which surfaces as an Open button on the card. Keep addresses out of message, since message is spoken aloud."),
        ]
        let statusLabel = "Scheduling"
        let statusIcon = LocalReminderTools.icon
        let group = LocalReminderTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let message = args.str("message") else { return .fail("message is required") }
            let when: Date
            switch LocalReminderTools.fireDate(args) {
            case .failure(let e): return .fail(e.message)
            case .success(let d):
                guard let d else { return .fail("Give delay_minutes or fire_at_iso.") }
                when = d
            }
            let rule = args.str("repeat") ?? "none"
            guard LocalReminderScheduler.validRepeats.contains(rule) else { return .fail("Unsupported repeat '\(rule)'. Use none, daily, weekdays, or weekly.") }
            if when.timeIntervalSinceNow < -60 && rule == "none" {
                return .fail("\(HDate.human(when)) already passed.", guidance: "Resolve the time against the current local time; if it passed today, use tomorrow.")
            }
            let url = args.str("url")
            let r = await MainActor.run { LocalReminderScheduler.shared.create(message: message, fireAt: when, repeatRule: rule, url: url) }
            var j = r.json(); j["ok"] = true
            return .ok(j, cards: [LocalReminderTools.card(r, title: "Reminder set")])
        }
    }

    struct Update: Tool {
        let name = "avo_update_reminder"
        let description = "Edits a reminder that already exists, whether the change is to its wording, its attached link, when it goes off, or how it repeats. Every modification the user asks for — 'change it to say X', 'make it 3 PM instead', 'attach the meeting link' — ALWAYS comes through here; NEVER make a fresh reminder in place of an edit, because the original survives and both then fire. The id comes from whatever the creation call returned, or from avo_list_scheduled. Whatever you leave out stays exactly as it was; only supplied fields move."
        let params = [
            ToolParam("id", "string", "The reminder id (from avo_create_reminder or avo_list_scheduled).", required: true),
            ToolParam("message", "string", "New reminder text."),
            ToolParam("url", "string", "An address to attach, typically a call's join link; the card renders it as an Open button. Addresses must not be written into message."),
            ToolParam("delay_minutes", "number", "New time as minutes from now. Use this OR fire_at_iso."),
            ToolParam("fire_at_iso", "string", "A replacement fixed time, in ISO-8601 with its timezone offset included. Leave this and the relative field alone and the existing schedule stands."),
            ToolParam("repeat", "string", "A replacement recurrence; passing 'none' ends repetition altogether. Omitting it preserves whatever pattern is set.", enumValues: ["none", "daily", "weekdays", "weekly"]),
        ]
        let statusLabel = "Updating"
        let statusIcon = LocalReminderTools.icon
        let group = LocalReminderTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let id = args.str("id") else { return .fail("id is required") }
            let when: Date?
            switch LocalReminderTools.fireDate(args) {
            case .failure(let e): return .fail(e.message)
            case .success(let d): when = d
            }
            let msg = args.str("message"), url = args.str("url"), rule = args.str("repeat")
            guard let r = await MainActor.run(body: { LocalReminderScheduler.shared.update(id: id, message: msg, fireAt: when, repeatRule: rule, url: url) }) else {
                return .fail("No reminder with id \(id).", guidance: "Call avo_list_scheduled to find the right id.")
            }
            var j = r.json(); j["ok"] = true
            return .ok(j, cards: [LocalReminderTools.card(r, title: "Reminder updated")])
        }
    }

    struct ListScheduled: Tool {
        let name = "avo_list_scheduled"
        let description = "Fetches the timed reminders held on this device, both still pending and lately fired, with each one's id, timing, recurrence and state. Set show_list=true ONLY where the user has actually asked to see everything: 'show all my reminders', 'what is scheduled?', 'what reminders do I have?'. Where the question concerns a single item ('is my Monday reminder set?'), or where you only need an id before cancelling or updating something, pass show_list=false, then give a yes or no and speak about the matching item alone — never recite the entire result."
        let params = [ToolParam("show_list", "boolean", "True purely where the user asked outright to see every reminder and scheduled item. Questions about a single one, and id lookups before making a change, use false.")]
        let statusLabel = "Checking schedule"
        let statusIcon = LocalReminderTools.icon
        let group = LocalReminderTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let items = await MainActor.run { LocalReminderScheduler.shared.listActive() }
            Log.info("avo_list_scheduled → \(items.count)")
            var cards: [CardKind] = []
            if args.bool("show_list") ?? false {
                let rows = items.prefix(6).map { r in
                    GlanceCard.Row(title: r.message, subtitle: r.repeats ? "Repeats \(r.repeatRule)" : nil, icon: r.status == "fired" ? "bell.fill" : "bell",
                                   trailing: r.status == "fired" ? "fired" : HDate.human(r.fireAt), tone: r.status == "fired" ? .accent : .neutral)
                }
                cards = [items.isEmpty ? Cards.note(source: "Avo", icon: LocalReminderTools.icon, title: "No reminders scheduled", body: "Nothing pending.")
                                       : Cards.glance(source: "Avo", icon: LocalReminderTools.icon, header: ("Scheduled", "\(items.count) reminder\(items.count == 1 ? "" : "s")"), rows: rows)]
            }
            return .ok(["ok": true, "count": items.count, "reminders": items.map { $0.json() }], cards: cards)
        }
    }

    struct Cancel: Tool {
        let name = "avo_cancel_scheduled"
        let description = "Cancel a local timed reminder by id (from avo_list_scheduled or the creation result). A cancelled reminder will NOT fire again; this also stops a repeating one."
        let params = [ToolParam("id", "string", "The reminder id to cancel.", required: true)]
        let statusLabel = "Cancelling"
        let statusIcon = LocalReminderTools.icon
        let group = LocalReminderTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let id = args.str("id") else { return .fail("id is required") }
            guard let r = await MainActor.run(body: { LocalReminderScheduler.shared.cancel(id: id) }) else {
                return .fail("No reminder with id \(id).", guidance: "Call avo_list_scheduled to find the right id.")
            }
            return .ok(["ok": true, "id": r.id, "message": r.message, "status": r.status])
        }
    }

    struct Snooze: Tool {
        let name = "avo_snooze_notification"
        let description = "Pushes back the card currently in front of the user, identified in your context as the ACTIVE NOTIFICATION CARD: it clears now and comes back once `minutes` have elapsed. It covers 'snooze it', 'remind me again in 30 minutes' and 'ask me later', and equally any timed 'remind me' that is really about deferring this card — 'not now, later', 'push it back 20 minutes', 'remind me in an hour (instead)'. Whenever the request concerns the card on screen, this beats avo_create_reminder. Durations up to a week are fine; leave minutes out and 30 applies."
        let params = [
            ToolParam("minutes", "number", "The gap before it returns, counted in minutes from now — 30 being both a typical value and what applies when nothing is given."),
            ToolParam("notification_id", "string", "Optional. The id given in the ACTIVE NOTIFICATION CARD context. Leaving it empty acts on whichever card is displayed at the moment."),
        ]
        let statusLabel = "Snoozing"
        let statusIcon = LocalReminderTools.icon
        let group = LocalReminderTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let minutes = min(max(Int((args.double("minutes") ?? 30).rounded()), 1), 7 * 24 * 60)
            let id = args.str("notification_id")
            guard let r = await MainActor.run(body: { LocalReminderScheduler.shared.snooze(id: id, minutes: minutes) }) else {
                return .fail("No reminder card is on screen to snooze.", guidance: "If the user wants a new timed reminder, call avo_create_reminder.")
            }
            var j = r.json(); j["ok"] = true; j["snoozed_minutes"] = minutes
            return .ok(j, cards: [LocalReminderTools.card(r, title: "Snoozed")])
        }
    }

    struct Dismiss: Tool {
        let name = "avo_dismiss_notification"
        let description = "Completes the card in front of the user and removes it from the screen; your context names it under ACTIVE NOTIFICATION CARD. Reach for it on 'mark it as done', 'dismiss it', 'got it' and 'clear that', and also once you have actually carried out whatever the notification was about. Note that nothing beyond the card changes — a repeating reminder remains scheduled, and avo_cancel_scheduled is what stops those."
        let params = [ToolParam("notification_id", "string", "Optional. The id given in the ACTIVE NOTIFICATION CARD context. Leaving it empty acts on whichever card is displayed at the moment.")]
        let statusLabel = "Dismissing"
        let statusIcon = LocalReminderTools.icon
        let group = LocalReminderTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let id = args.str("notification_id")
            guard let r = await MainActor.run(body: { LocalReminderScheduler.shared.dismiss(id: id) }) else {
                return .fail("No reminder card is on screen.", guidance: "Nothing to dismiss; acknowledge briefly.")
            }
            return .ok(["ok": true, "id": r.id, "message": r.message, "status": r.status])
        }
    }
}

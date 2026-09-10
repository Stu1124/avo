import Foundation

/// Starts the local scheduling services (scheduled actions, reply watches, email monitors). Cheap when nothing is scheduled: no timers run.
@MainActor
final class SchedulingServices {
    static let shared = SchedulingServices()
    private var started = false
    func start() {
        guard !started else { return }
        started = true
        ScheduledActionStore.shared.start()
        ReplyWatch.shared.start()
        EmailMonitorService.shared.start()
    }
}

/// Reminder ids the user paused through pause_scheduled_item. LocalReminderScheduler has no paused state, so a paused
/// reminder is a cancelled one we remember and can resume.
enum PausedReminders {
    private static let key = "avo.pausedReminderIds"
    static var ids: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: key) }
    }
}

// MARK: - Tools

enum SchedulingTools {
    static let group = "Scheduling"
    static let icon = ScheduledActionStore.icon

    static func all() -> [Tool] {
        [ScheduleAction(), CreateEmailMonitor(), ListScheduled(), CancelItem(), PauseItem(), ResumeItem()]
    }

    /// Which store an id belongs to, by prefix.
    enum Kind { case action, monitor, watch, reminder }
    static func kind(of id: String) -> Kind {
        if id.hasPrefix("act-") { return .action }
        if id.hasPrefix("mon-") { return .monitor }
        if id.hasPrefix("rw-") { return .watch }
        return .reminder
    }

    static func reminderJSON(_ r: LocalReminder) -> [String: Any] {
        var j = r.json(); j["kind"] = "reminder"
        if PausedReminders.ids.contains(r.id), r.status == "cancelled" { j["status"] = "paused"; j.removeValue(forKey: "in") }
        return j
    }

    // MARK: schedule_action

    struct ScheduleAction: Tool {
        let name = "schedule_action"
        let description = "Queues a REAL action that genuinely happens later — an iMessage or email going out, a calendar event or reminder being created — and it happens EXACTLY as approved here, because the arguments are frozen and replayed later with no model in the loop. That means ALL the work has to be done now: write the message or email in full, choose which inner tool runs, and populate tool_arguments COMPLETELY, with every single field that tool needs (gmail_send wants to, subject and body; send_message wants chat_guid, to and message, so resolve the chat_guid before you call). Those exact arguments appear on a confirmation card where the user can adjust them, and whatever they approve is what executes. Express perform_at_iso in ISO-8601 carrying the user's timezone offset. Each item fires once and once only; repeating actions are NOT supported, so say as much if the user asks for one. Should Avo be closed when the moment arrives, the action still runs if the app returns inside about an hour, and otherwise the user is told plainly that it did NOT run. A bare timed 'remind me' is avo_create_reminder's job, not this one."
        let params = [
            ToolParam("title", "string", "A single ordinary sentence saying what will happen — 'Send the project update email to Bob' is the shape. It appears on the confirmation card and in any notification.", required: true),
            ToolParam("perform_at_iso", "string", "The moment it should fire, given in ISO-8601 including the timezone offset, as in '2026-07-18T17:00:00-07:00'.", required: true),
            ToolParam("inner_tool", "string", "Which tool actually executes at the appointed time. The choices are send_message for iMessage, gmail_send, gmail_reply, gcal_create_event, and create_reminder for Apple Reminders. There is no draft option in Gmail — new mail goes out through gmail_send.", required: true, enumValues: ScheduledAction.innerTools),
            ToolParam("tool_arguments", "object", "Everything inner_tool would receive if you invoked it yourself, with nothing left out. Approval locks this object, and it is replayed unchanged.", required: true),
        ]
        let statusLabel = "Scheduling"
        let statusIcon = SchedulingTools.icon
        let group = SchedulingTools.group
        var confirmation: ConfirmationSpec? {
            ConfirmationSpec(icon: SchedulingTools.icon, title: "Schedule action",
                             subtitle: { a in
                                 let when = a.str("perform_at_iso").flatMap { HDate.parse($0) }.map(HDate.human) ?? "?"
                                 let inner = a.str("inner_tool") ?? ""
                                 let probe = ScheduledAction(id: "", title: "", innerTool: inner, argumentsJSON: SchedulingTools.argumentsJSON(a["tool_arguments"]),
                                                             performAt: Date(), status: "", createdAt: Date(), ranAt: nil, error: nil)
                                 return "\(when) · \(probe.summary)"
                             },
                             fields: [(key: "title", label: "Action", kind: .text, required: true),
                                      (key: "perform_at_iso", label: "Run at", kind: .datetime, required: true),
                                      (key: "tool_arguments", label: "Arguments (JSON, replayed verbatim)", kind: .multiline, required: true)],
                             confirmLabel: "Schedule")
        }
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let title = args.str("title") else { return .fail("title is required") }
            guard let inner = args.str("inner_tool") else { return .fail("inner_tool is required") }
            guard ScheduledAction.innerTools.contains(inner) else {
                return .fail("inner_tool '\(inner)' can't be scheduled.", guidance: "Supported: \(ScheduledAction.innerTools.joined(separator: ", ")). Tell the user if their request needs something else.")
            }
            guard let whenRaw = args.str("perform_at_iso"), let when = HDate.parse(whenRaw) else {
                return .fail("Could not parse perform_at_iso '\(args.str("perform_at_iso") ?? "")'.", guidance: "Use ISO-8601 with an offset, e.g. 2026-07-18T17:00:00-07:00.")
            }
            if when.timeIntervalSinceNow < -60 {
                return .fail("\(HDate.human(when)) already passed.", guidance: "Resolve the time against the current local time; if it passed today, use tomorrow. If the user wants it now, call \(inner) directly.")
            }
            let toolArgs = JSON.parse(SchedulingTools.argumentsJSON(args["tool_arguments"]))
            if toolArgs.isEmpty {
                let raw = JSON.string(args["tool_arguments"]) ?? ""
                return .fail(raw.isEmpty ? "tool_arguments is required." : "tool_arguments is not a JSON object.", guidance: "Pass the complete arguments for \(inner) as a JSON object.")
            }
            let tool = await MainActor.run { ToolRegistry.shared.enabledTool(inner) }
            guard let tool else { return .fail("\(inner) is not available (integration disabled).", guidance: "Tell the user that integration is turned off in Avo settings.") }
            let missing = tool.params.filter { $0.required && toolArgs.str($0.name) == nil && (toolArgs[$0.name] as? [Any])?.isEmpty != false }.map(\.name)
            if !missing.isEmpty {
                return .fail("tool_arguments is missing required fields for \(inner): \(missing.joined(separator: ", ")).", guidance: "Fill every required field, then call schedule_action again.")
            }
            let a = await MainActor.run { ScheduledActionStore.shared.create(title: title, innerTool: inner, arguments: toolArgs, performAt: when) }
            var j = a.json(); j["ok"] = true
            let card = CardKind.glance(GlanceCard(id: UUID(), blocks: [
                .header(title: "Scheduled", subtitle: "\(HDate.human(when)) · \(HDate.countdown(to: when))", icon: a.icon),
                .keyValue(pairs: [("Action", title)] + a.keyPairs.prefix(3)),
            ], source: "Avo", sourceIcon: SchedulingTools.icon))
            return .ok(j, cards: [card], narration: "Scheduled for \(HDate.human(when)).")
        }
    }

    /// tool_arguments arrives as an object from the model, or as a JSON string after the user edits the card.
    static func argumentsJSON(_ v: Any?) -> String {
        if let d = v as? [String: Any] { return JSON.stringify(d) }
        if let s = v as? String { return s }
        return "{}"
    }

    // MARK: create_email_monitor

    struct CreateEmailMonitor: Tool {
        let name = "create_email_monitor"
        let description = "Keeps an eye on Gmail and raises a notification the moment a NEW message fits the criteria — this is what 'tell me when Stripe emails me' or 'let me know when the invoice from Acme lands' asks for. Gmail is the only mailbox wired up, so source is gmail; if someone names outlook or applemail, explain that monitoring does not cover that source. Translate the request into fixed filters NOW, before you call: companies belong in from_domains (stripe.com), individual people or addresses in from_contains, topics in subject_contains. A check runs every couple of minutes and does nothing but literal string comparison — no model reads the mail. Messages already sitting in the inbox NEVER trigger anything, and each NEW match notifies exactly one time. Requests aimed anywhere else, whether Slack, calendars, web pages or prices, get the same answer: monitoring does not cover that source."
        let params = [
            ToolParam("source", "string", "Which linked mailbox gets watched — gmail, outlook, or applemail as values, though gmail is the only one Avo actually connects to.", required: true, enumValues: ["gmail", "outlook", "applemail"]),
            ToolParam("label", "string", "A brief readable name for this watch, along the lines of 'Stripe emails'; notifications quote it.", required: true),
            ToolParam("from_domains", "array", "Domains a sender must belong to, written bare as ['stripe.com']; subdomains count as matches too.", items: "string"),
            ToolParam("from_contains", "array", "Fragments to look for inside a sender's name or address — ['bob'] and ['bob@acme.com'] are both valid.", items: "string"),
            ToolParam("subject_contains", "array", "Substrings the subject must contain (any of them): ['invoice'].", items: "string"),
        ]
        let statusLabel = "Setting up monitor"
        let statusIcon = EmailMonitorService.icon
        let group = SchedulingTools.group
        var confirmation: ConfirmationSpec? {
            ConfirmationSpec(icon: EmailMonitorService.icon, title: "Watch Gmail", subtitle: { $0.str("label") },
                             fields: [(key: "label", label: "Label", kind: .text, required: true),
                                      (key: "from_domains", label: "From domains", kind: .text, required: false),
                                      (key: "from_contains", label: "From contains", kind: .text, required: false),
                                      (key: "subject_contains", label: "Subject contains", kind: .text, required: false)],
                             confirmLabel: "Watch")
        }
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let source = (args.str("source") ?? "gmail").lowercased()
            guard source == "gmail" else { return .fail("Only Gmail monitoring is supported in Avo (not \(source)).", guidance: "Explain to the user that Avo cannot watch that source.") }
            guard let label = args.str("label") else { return .fail("label is required") }
            let domains = GoogleAPI.strings(args["from_domains"]), froms = GoogleAPI.strings(args["from_contains"]), subjects = GoogleAPI.strings(args["subject_contains"])
            guard !(domains.isEmpty && froms.isEmpty && subjects.isEmpty) else {
                return .fail("No filters given.", guidance: "Compile the request into from_domains, from_contains and/or subject_contains.")
            }
            return await GoogleAPI.gated {
                let m = await EmailMonitorService.shared.create(label: label, fromDomains: domains, fromContains: froms, subjectContains: subjects)
                var j = m.json(); j["ok"] = true
                let card = Cards.glance(source: "Avo", icon: EmailMonitorService.icon, header: ("Watching Gmail", label), text: m.filterSummary)
                return .ok(j, cards: [card], narration: "Watching Gmail for \(label).")
            }
        }
    }

    // MARK: list_scheduled

    struct ListScheduled: Tool {
        let name = "list_scheduled"
        let description = "Fetches everything the user has pending — reminders, scheduled actions, email monitors and reply watches, whether running or paused — together with each one's id, timing and state. Reply watches appear on their own whenever a message or email goes out through Avo, and they fire a single notification once an answer comes back. Set show_list=true ONLY where the user has actually asked to see the lot: 'show all my reminders', 'what is scheduled?', 'what reminders do I have?'. Where they ask about one item ('is my Monday reminder set?'), or where you are simply resolving an id ahead of cancelling, updating, pausing or resuming something, set show_list=false, then reply yes or no and speak only about the item that matched — never read the whole result out."
        let params = [ToolParam("show_list", "boolean", "Set it true purely when the user asked outright to see every reminder and scheduled item. Questions about one item, and id lookups made before changing something, use false.")]
        let statusLabel = "Checking schedule"
        let statusIcon = SchedulingTools.icon
        let group = SchedulingTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let (reminders, actions, monitors, watches) = await MainActor.run { () -> ([LocalReminder], [ScheduledAction], [EmailMonitorItem], [ReplyWatchItem]) in
                let paused = PausedReminders.ids
                let sched = LocalReminderScheduler.shared
                let rs = sched.listActive() + sched.reminders.filter { paused.contains($0.id) && $0.status == "cancelled" }
                return (rs, ScheduledActionStore.shared.listActive(), EmailMonitorService.shared.listActive(), ReplyWatch.shared.listActive())
            }
            let count = reminders.count + actions.count + monitors.count + watches.count
            Log.info("list_scheduled → \(reminders.count) reminders, \(actions.count) actions, \(monitors.count) monitors, \(watches.count) watches")
            var cards: [CardKind] = []
            if args.bool("show_list") ?? false {
                var rows: [GlanceCard.Row] = []
                let paused = PausedReminders.ids
                for r in reminders {
                    let isPaused = paused.contains(r.id) && r.status == "cancelled"
                    rows.append(.init(title: r.message, subtitle: "Reminder" + (r.repeats ? " · \(r.repeatRule)" : ""), icon: r.status == "fired" ? "bell.fill" : "bell",
                                      trailing: isPaused ? "paused" : (r.status == "fired" ? "fired" : HDate.human(r.fireAt)), tone: r.status == "fired" ? .accent : .neutral))
                }
                for a in actions {
                    rows.append(.init(title: a.title, subtitle: "Scheduled action · \(a.summary)".preview(70), icon: a.icon,
                                      trailing: a.isPending ? HDate.human(a.performAt) : a.status, tone: a.status == "failed" || a.status == "missed" ? .bad : (a.status == "done" ? .good : .neutral)))
                }
                for m in monitors {
                    rows.append(.init(title: m.label, subtitle: "Gmail monitor · \(m.filterSummary)".preview(70), icon: EmailMonitorService.icon,
                                      trailing: m.status == "paused" ? "paused" : "every 2 min"))
                }
                for w in watches {
                    rows.append(.init(title: "Reply from \(w.label)", subtitle: "Reply watch · sent \(HDate.human(w.sentAt))", icon: w.icon,
                                      trailing: w.status == "paused" ? "paused" : "until \(HDate.humanDay(w.expiresAt))"))
                }
                cards = [rows.isEmpty ? Cards.note(source: "Avo", icon: SchedulingTools.icon, title: "Nothing scheduled", body: "No reminders, actions, monitors or reply watches.")
                                      : Cards.glance(source: "Avo", icon: SchedulingTools.icon, header: ("Scheduled", "\(count) item\(count == 1 ? "" : "s")" + (count > 6 ? " · showing 6" : "")), rows: rows)]
            }
            return .ok(["ok": true, "count": count,
                        "reminders": reminders.map(SchedulingTools.reminderJSON),
                        "scheduled_actions": actions.map { $0.json() },
                        "email_monitors": monitors.map { $0.json() },
                        "reply_watches": watches.map { $0.json() }], cards: cards)
        }
    }

    // MARK: cancel / pause / resume

    static let idGuidance = "Call list_scheduled (show_list=false) to find the right id."

    struct CancelItem: Tool {
        let name = "cancel_scheduled_item"
        let description = "Removes a pending item — reminder, scheduled action, email monitor or reply watch — addressed by the id list_scheduled gives. A cancelled scheduled action will NOT run. This is also how the user stops waiting on somebody's reply. Reminder ids are accepted here as well, behaving exactly as avo_cancel_scheduled would."
        let params = [ToolParam("id", "string", "The item id from list_scheduled (reminder id, act-…, mon-…, or rw-…).", required: true)]
        let statusLabel = "Cancelling"
        let statusIcon = SchedulingTools.icon
        let group = SchedulingTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let id = args.str("id") else { return .fail("id is required") }
            let result: [String: Any]? = await MainActor.run {
                switch SchedulingTools.kind(of: id) {
                case .action: return ScheduledActionStore.shared.cancel(id: id).map { ["id": $0.id, "kind": "scheduled_action", "title": $0.title, "status": $0.status] }
                case .monitor: return EmailMonitorService.shared.cancel(id: id).map { ["id": $0.id, "kind": "email_monitor", "label": $0.label, "status": $0.status] }
                case .watch: return ReplyWatch.shared.cancel(id: id).map { ["id": $0.id, "kind": "reply_watch", "watching": $0.label, "status": $0.status] }
                case .reminder:
                    PausedReminders.ids.remove(id)
                    return LocalReminderScheduler.shared.cancel(id: id).map { ["id": $0.id, "kind": "reminder", "message": $0.message, "status": $0.status] }
                }
            }
            guard var j = result else { return .fail("No scheduled item with id \(id).", guidance: SchedulingTools.idGuidance) }
            j["ok"] = true
            return .ok(j)
        }
    }

    struct PauseItem: Tool {
        let name = "pause_scheduled_item"
        let description = "Suspends a reminder, email monitor or reply watch, named by id: it remains in the list yet stays silent until it is resumed. Pausing is unavailable for scheduled actions, which have to be cancelled outright."
        let params = [ToolParam("id", "string", "The item id from list_scheduled.", required: true)]
        let statusLabel = "Pausing"
        let statusIcon = "pause.circle.fill"
        let group = SchedulingTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let id = args.str("id") else { return .fail("id is required") }
            if SchedulingTools.kind(of: id) == .action {
                return .fail("Scheduled actions can't be paused.", guidance: "Cancel it with cancel_scheduled_item instead, or reschedule with schedule_action.")
            }
            let result: [String: Any]? = await MainActor.run {
                switch SchedulingTools.kind(of: id) {
                case .monitor: return EmailMonitorService.shared.pause(id: id).map { ["id": $0.id, "kind": "email_monitor", "label": $0.label, "status": $0.status] }
                case .watch: return ReplyWatch.shared.pause(id: id).map { ["id": $0.id, "kind": "reply_watch", "watching": $0.label, "status": $0.status] }
                default:
                    guard let r = LocalReminderScheduler.shared.find(id) else { return nil }
                    if r.status == "scheduled" || r.status == "fired" { _ = LocalReminderScheduler.shared.cancel(id: id) }
                    PausedReminders.ids.insert(id)
                    return ["id": r.id, "kind": "reminder", "message": r.message, "status": "paused"]
                }
            }
            guard var j = result else { return .fail("No scheduled item with id \(id).", guidance: SchedulingTools.idGuidance) }
            j["ok"] = true
            return .ok(j)
        }
    }

    struct ResumeItem: Tool {
        let name = "resume_scheduled_item"
        let description = "Restarts a suspended reminder, email monitor or reply watch by id. Anything recurring picks up from its next scheduled occurrence, while a single-shot reminder whose moment has already gone off fires straight away, flagged overdue."
        let params = [ToolParam("id", "string", "The item id from list_scheduled.", required: true)]
        let statusLabel = "Resuming"
        let statusIcon = "play.circle.fill"
        let group = SchedulingTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let id = args.str("id") else { return .fail("id is required") }
            if SchedulingTools.kind(of: id) == .action { return .fail("Scheduled actions can't be paused or resumed.", guidance: "Reschedule with schedule_action if needed.") }
            let result: [String: Any]? = await MainActor.run {
                switch SchedulingTools.kind(of: id) {
                case .monitor: return EmailMonitorService.shared.resume(id: id).map { ["id": $0.id, "kind": "email_monitor", "label": $0.label, "status": $0.status] }
                case .watch: return ReplyWatch.shared.resume(id: id).map { ["id": $0.id, "kind": "reply_watch", "watching": $0.label, "status": $0.status] }
                default:
                    let sched = LocalReminderScheduler.shared
                    guard let r = sched.find(id) else { return nil }
                    PausedReminders.ids.remove(id)
                    if r.status == "scheduled" { var j = r.json(); j["kind"] = "reminder"; j["note"] = "Already active."; return j }
                    // Recurring: skip to the next occurrence. One-shot: keep its time; if it passed it fires now as overdue.
                    let next = r.repeats ? LocalReminderScheduler.nextOccurrence(after: Date(), from: r.fireAt, rule: r.repeatRule) : nil
                    guard let u = sched.update(id: id, message: nil, fireAt: next, repeatRule: nil, url: nil, revive: true) else { return nil }
                    var j = u.json(); j["kind"] = "reminder"; return j
                }
            }
            guard var j = result else { return .fail("No scheduled item with id \(id).", guidance: SchedulingTools.idGuidance) }
            j["ok"] = true
            return .ok(j)
        }
    }
}

import EventKit
import AppKit
import Foundation

/// Apple Reminders via EventKit. One shared store, full-access request on first use.
final class RemindersStore: @unchecked Sendable {
    static let shared = RemindersStore()
    static let icon = "app:com.apple.reminders"
    let store = EKEventStore()
    private let lock = NSLock()
    private var listNames: [String] = []

    enum Failure: Error, CustomStringConvertible {
        case denied, noList(String), ambiguous([String]), notFound(String)
        var description: String {
            switch self {
            case .denied: return "Reminders access is not granted."
            case .noList(let n): return "No Reminders list named '\(n)'."
            case .ambiguous(let c): return "Several reminders match: \(c.joined(separator: "; "))."
            case .notFound(let n): return "No reminder matched '\(n)'."
            }
        }
    }

    static let deniedGuidance = PermissionGate.guidance(.reminders)

    /// Cached list names for the create-reminder confirmation select. Warmed without prompting when access already exists.
    var cachedListNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return listNames
    }

    func warmIfAuthorized() {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return }
        let names = store.calendars(for: .reminder).map(\.title).sorted()
        lock.lock(); listNames = names; lock.unlock()
        Log.info("Reminders: \(names.count) lists cached")
    }

    /// Just-in-time gate: onboarding never asks for Reminders, so the first tool that needs it
    /// shows the system prompt, or a card explaining what is missing.
    func access() async throws {
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { refreshLists(); return }
        guard await PermissionGate.ensure(.reminders) else { throw Failure.denied }
        refreshLists()
    }

    private func refreshLists() {
        let names = store.calendars(for: .reminder).map(\.title).sorted()
        lock.lock(); listNames = names; lock.unlock()
    }

    /// List name → hex color, for the reminder card's circle and list dot.
    func listColors() -> [String: String] {
        var out: [String: String] = [:]
        for c in store.calendars(for: .reminder) {
            if let cg = c.cgColor, let hex = CardBrand.hex(NSColor(cgColor: cg)) { out[c.title] = hex }
        }
        return out
    }
    /// Marks one reminder done (from the card's checkbox); errors are logged, not surfaced.
    func complete(identifier: String) {
        guard let r = store.calendarItem(withIdentifier: identifier) as? EKReminder, !r.isCompleted else { return }
        r.isCompleted = true
        do { try store.save(r, commit: true) } catch { Log.error("Reminder complete failed: \(error)") }
    }
    var lists: [EKCalendar] { store.calendars(for: .reminder).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } }

    func list(named name: String?) throws -> EKCalendar? {
        guard let name, !name.isEmpty else { return nil }
        let all = lists
        if let c = all.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) { return c }
        if let c = all.first(where: { $0.title.range(of: name, options: .caseInsensitive) != nil }) { return c }
        throw Failure.noList(name)
    }

    func defaultList() -> EKCalendar? {
        let all = lists
        // No configured name (the default) means Reminders' own default list decides.
        let name = AppleTools.defaultReminderList
        if !name.isEmpty, let match = all.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) { return match }
        return store.defaultCalendarForNewReminders() ?? all.first
    }

    func fetch(_ predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
        }
    }

    func incomplete(in calendars: [EKCalendar]?) async -> [EKReminder] {
        await fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars))
    }

    func allReminders(in calendars: [EKCalendar]?) async -> [EKReminder] {
        await fetch(store.predicateForReminders(in: calendars))
    }

    static func dueDate(_ r: EKReminder) -> Date? {
        guard let c = r.dueDateComponents else { return nil }
        return Calendar.current.date(from: c)
    }

    static func json(_ r: EKReminder) -> [String: Any] {
        var j: [String: Any] = ["reminder_id": r.calendarItemIdentifier, "title": r.title ?? "", "list": r.calendar?.title ?? "", "completed": r.isCompleted]
        if let n = r.notes, !n.isEmpty { j["notes"] = n }
        if let d = dueDate(r) {
            let hasTime = r.dueDateComponents?.hour != nil
            j["due"] = hasTime ? HDate.human(d) : HDate.humanDay(d)
            j["due_iso"] = HDate.iso(d)
        }
        if r.priority > 0 { j["priority"] = r.priority }
        return j
    }

    static func sortByDue(_ rs: [EKReminder]) -> [EKReminder] {
        rs.sorted {
            switch (dueDate($0), dueDate($1)) {
            case let (a?, b?): return a < b
            case (.some, .none): return true
            case (.none, .some): return false
            default: return ($0.title ?? "") < ($1.title ?? "")
            }
        }
    }

    static func row(_ r: EKReminder, showList: Bool) -> GlanceCard.Row {
        let due = dueDate(r)
        var tone: GlanceCard.Tone = .neutral
        if let d = due, d < Date(), !r.isCompleted { tone = .bad }
        let sub = showList ? r.calendar?.title : (r.notes?.preview(60))
        var row = GlanceCard.Row(title: r.title ?? "Untitled", subtitle: sub, icon: r.isCompleted ? "checkmark.circle.fill" : "circle",
                                 trailing: due.map { r.dueDateComponents?.hour != nil ? HDate.human($0) : HDate.humanDay($0) }, tone: tone)
        row.accent = r.calendar?.cgColor.flatMap { CardBrand.hex(NSColor(cgColor: $0)) }
        if !r.isCompleted {
            row.checkable = true
            let id = r.calendarItemIdentifier
            row.onToggle = { Task.detached { RemindersStore.shared.complete(identifier: id) } }
        }
        return row
    }
}

enum RemindersTools {
    static let group = "Reminders"
    static let icon = RemindersStore.icon

    static func all() -> [Tool] {
        RemindersStore.shared.warmIfAuthorized()
        return [ListLists(), ListReminders(), SearchReminders(), CreateReminder(), CompleteReminder()]
    }

    static func failure(_ e: Error) -> ToolResult {
        if case RemindersStore.Failure.denied = e { return .fail("\(e)", guidance: RemindersStore.deniedGuidance) }
        return .fail("\(e)")
    }

    struct ListLists: Tool {
        let name = "list_reminder_lists"
        let description = "Enumerates the lists inside Reminders — 'Reminders', 'Groceries', 'Work' and whatever else the user keeps — showing how many unfinished items sit in each. Call it before reading or adding anything, so you know which lists actually exist."
        let params: [ToolParam] = []
        let statusLabel = "Reading lists"
        let statusIcon = RemindersTools.icon
        let group = RemindersTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let s = RemindersStore.shared
            do { try await s.access() } catch { return RemindersTools.failure(error) }
            let lists = s.lists
            let open = await s.incomplete(in: nil)
            var counts: [String: Int] = [:]
            for r in open { counts[r.calendar?.calendarIdentifier ?? "", default: 0] += 1 }
            let def = s.defaultList()
            let json: [[String: Any]] = lists.map { ["name": $0.title, "incomplete": counts[$0.calendarIdentifier] ?? 0, "default": $0.calendarIdentifier == def?.calendarIdentifier] }
            Log.info("Reminders lists → \(lists.count)")
            let rows = lists.prefix(6).map { GlanceCard.Row(title: $0.title, subtitle: $0.calendarIdentifier == def?.calendarIdentifier ? "Default" : nil, icon: "list.bullet", trailing: "\(counts[$0.calendarIdentifier] ?? 0)") }
            return .ok(["ok": true, "lists": json], cards: [Cards.glance(source: "Reminders", icon: RemindersTools.icon, rows: rows)])
        }
    }

    struct ListReminders: Tool {
        let name = "list_reminders"
        let description = "Returns reminders, either everywhere or restricted to one list, and by default leaves out anything already finished. Every entry carries its list, title, notes, due date, whether it is done, and the reminder_id that completing it requires. Behind questions like 'what's on my to-do list?' and 'what's due today?'."
        let params = [
            ToolParam("list", "string", "One list's name, spelled as list_reminder_lists reports it. Left out, every list is covered."),
            ToolParam("include_completed", "boolean", "Pass true to bring finished reminders into the results as well. It is false unless set, so only unfinished ones come back."),
            ToolParam("limit", "integer", "Maximum number of reminders to return (default 30)."),
        ]
        let statusLabel = "Reading reminders"
        let statusIcon = RemindersTools.icon
        let group = RemindersTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let s = RemindersStore.shared
            do { try await s.access() } catch { return RemindersTools.failure(error) }
            let cal: EKCalendar?
            do { cal = try s.list(named: args.str("list")) } catch { return .fail("\(error)", guidance: "Call list_reminder_lists for the exact names.") }
            let scope = cal.map { [$0] }
            let includeDone = args.bool("include_completed") ?? false
            var rs = includeDone ? await s.allReminders(in: scope) : await s.incomplete(in: scope)
            rs = RemindersStore.sortByDue(rs)
            let limit = max(args.int("limit") ?? 30, 1)
            let shown = Array(rs.prefix(limit))
            Log.info("Reminders list \(cal?.title ?? "all") → \(rs.count)")
            let header = (cal?.title ?? "Reminders", "\(rs.count) \(includeDone ? "item" : "open")\(rs.count == 1 ? "" : "s")")
            let card = shown.isEmpty
                ? Cards.note(source: "Reminders", icon: RemindersTools.icon, title: header.0, body: "Nothing here.")
                : Cards.glance(source: "Reminders", icon: RemindersTools.icon, header: header, rows: shown.prefix(6).map { RemindersStore.row($0, showList: cal == nil) })
            return .ok(["ok": true, "count": rs.count, "reminders": shown.map(RemindersStore.json)], cards: [card])
        }
    }

    struct SearchReminders: Tool {
        let name = "search_reminders"
        let description = "Scans every list, finished items included, for a phrase appearing in a reminder's title or its notes. Each match returns with its list, title, notes, due date and reminder_id. It answers 'did I already add milk?' and 'find my reminder about the dentist'."
        let params = [ToolParam("query", "string", "Words to look for in reminder titles and notes.", required: true)]
        let statusLabel = "Searching reminders"
        let statusIcon = RemindersTools.icon
        let group = RemindersTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let q = args.str("query") else { return .fail("query is required") }
            let s = RemindersStore.shared
            do { try await s.access() } catch { return RemindersTools.failure(error) }
            let all = await s.allReminders(in: nil)
            let hits = RemindersStore.sortByDue(all.filter {
                ($0.title ?? "").range(of: q, options: .caseInsensitive) != nil || ($0.notes ?? "").range(of: q, options: .caseInsensitive) != nil
            })
            Log.info("Reminders search '\(q)' → \(hits.count)")
            let card = hits.isEmpty ? [] : [Cards.glance(source: "Reminders", icon: RemindersTools.icon, header: ("\"\(q)\"", "\(hits.count) match\(hits.count == 1 ? "" : "es")"), rows: hits.prefix(6).map { RemindersStore.row($0, showList: true) })]
            return .ok(["ok": true, "count": hits.count, "reminders": hits.prefix(40).map(RemindersStore.json)], cards: card)
        }
    }

    struct CreateReminder: Tool {
        let name = "create_reminder"
        let description = "Adds an item to Apple's Reminders app. Only the title is required; a list drawn from list_reminder_lists, some notes, and a due date or time are all optional, and with no list named the default one receives it. This is the tool for 'add eggs to my Groceries list' and 'put call the bank on my Errands list'. Anything phrased as an alarm — 'remind me in 10 minutes', 'remind me at 5' — goes to avo_create_reminder rather than here."
        let params = [
            ToolParam("title", "string", "The reminder text, e.g. 'Call the bank'.", required: true),
            ToolParam("list", "string", "Which list receives the item, named the way list_reminder_lists reports it. With nothing given, the default list in Reminders takes it."),
            ToolParam("due", "string", "Optional. When the item is due, written in ISO 8601 form such as '2026-06-10T09:00:00'. Supply a bare date and it is treated as 9:00am on that day."),
            ToolParam("notes", "string", "Optional notes/body for the reminder."),
        ]
        let statusLabel = "Adding reminder"
        let statusIcon = RemindersTools.icon
        let group = RemindersTools.group
        var confirmation: ConfirmationSpec? {
            // The picker offers the lists that exist; an unset default is not one of them.
            let names = RemindersStore.shared.cachedListNames
            return ConfirmationSpec(icon: RemindersTools.icon, title: "Add reminder", subtitle: { $0.str("title") },
                                    fields: [(key: "title", label: "Title", kind: .text, required: true),
                                             (key: "list", label: "List", kind: .select(names), required: false),
                                             (key: "due", label: "Due", kind: .text, required: false),
                                             (key: "notes", label: "Notes", kind: .multiline, required: false)],
                                    confirmLabel: "Add", layout: .reminder)
        }
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let title = args.str("title") else { return .fail("title is required") }
            let s = RemindersStore.shared
            do { try await s.access() } catch { return RemindersTools.failure(error) }
            let cal: EKCalendar?
            do { cal = try s.list(named: args.str("list")) ?? s.defaultList() } catch { return .fail("\(error)", guidance: "Call list_reminder_lists for the exact names.") }
            guard let cal else { return .fail("No Reminders list available.") }
            var due: Date?
            if let d = args.str("due") {
                guard let parsed = HDate.parse(d) else { return .fail("Could not parse due '\(d)'.", guidance: "Pass ISO 8601 like 2026-06-10T09:00:00.") }
                due = parsed
            }
            let r = EKReminder(eventStore: s.store)
            r.title = title
            r.calendar = cal
            if let n = args.str("notes") { r.notes = n }
            if let due {
                let hasTime = !(args.str("due")?.count == 10)
                r.dueDateComponents = Calendar.current.dateComponents(hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: due)
                if hasTime { r.addAlarm(EKAlarm(absoluteDate: due)) }
            }
            do { try s.store.save(r, commit: true) } catch { return .fail("Could not save reminder: \(error.localizedDescription)") }
            Log.info("Reminders created '\(title)' in \(cal.title)")
            let sub = [cal.title, due.map(HDate.human)].compactMap { $0 }.joined(separator: " · ")
            return .ok(["ok": true, "reminder_id": r.calendarItemIdentifier, "title": title, "list": cal.title, "due": due.map(HDate.human) ?? ""],
                       cards: [Cards.glance(source: "Reminders", icon: RemindersTools.icon, header: (title, sub))])
        }
    }

    struct CompleteReminder: Tool {
        let name = "complete_reminder"
        let description = "Ticks a reminder off. The dependable way in is the reminder_id that list_reminders or search_reminders returns. A title works as an alternative, optionally narrowed by list, but where a title fits more than one reminder the call refuses instead of guessing. This handles 'check off buy milk' and 'mark my dentist reminder done'."
        let params = [
            ToolParam("reminder_id", "string", "A reminder_id exactly as list_reminders or search_reminders produced it. Addressing an item this way is the reliable route, and the one to prefer."),
            ToolParam("name", "string", "A reminder's title, consulted only where no reminder_id was supplied. It has to pick out exactly one unfinished reminder and no more."),
            ToolParam("list", "string", "Optional list name to narrow a name match."),
        ]
        let statusLabel = "Completing"
        let statusIcon = RemindersTools.icon
        let group = RemindersTools.group
        var confirmation: ConfirmationSpec? {
            ConfirmationSpec(icon: RemindersTools.icon, title: "Complete reminder", subtitle: { $0.str("name") },
                             fields: [(key: "name", label: "Reminder", kind: .text, required: false)], confirmLabel: "Done")
        }
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let s = RemindersStore.shared
            do { try await s.access() } catch { return RemindersTools.failure(error) }
            var target: EKReminder?
            if let id = args.str("reminder_id") {
                target = s.store.calendarItem(withIdentifier: id) as? EKReminder
                if target == nil { target = await s.allReminders(in: nil).first { $0.calendarItemIdentifier == id } }
                if target == nil { return .fail("No reminder with id \(id).", guidance: "Call list_reminders to refresh ids.") }
            } else if let n = args.str("name") {
                let cal: EKCalendar?
                do { cal = try s.list(named: args.str("list")) } catch { return .fail("\(error)") }
                let open = await s.incomplete(in: cal.map { [$0] })
                var hits = open.filter { ($0.title ?? "").caseInsensitiveCompare(n) == .orderedSame }
                if hits.isEmpty { hits = open.filter { ($0.title ?? "").range(of: n, options: .caseInsensitive) != nil } }
                if hits.isEmpty { return .fail("\(RemindersStore.Failure.notFound(n))", guidance: "Call search_reminders to find it.") }
                if hits.count > 1 { return .fail("\(RemindersStore.Failure.ambiguous(hits.map { "\($0.title ?? "") (\($0.calendar?.title ?? ""), id \($0.calendarItemIdentifier))" }))", guidance: "Ask the user which one, then pass reminder_id.") }
                target = hits.first
            } else {
                return .fail("Pass reminder_id or name.")
            }
            guard let r = target else { return .fail("Reminder not found.") }
            if r.isCompleted { return .ok(["ok": true, "already_completed": true, "title": r.title ?? ""]) }
            r.isCompleted = true
            r.completionDate = Date()
            do { try s.store.save(r, commit: true) } catch { return .fail("Could not save: \(error.localizedDescription)") }
            Log.info("Reminders completed '\(r.title ?? "")'")
            return .ok(["ok": true, "reminder_id": r.calendarItemIdentifier, "title": r.title ?? "", "list": r.calendar?.title ?? ""],
                       cards: [Cards.glance(source: "Reminders", icon: RemindersTools.icon, header: (r.title ?? "Done", "Completed"))])
        }
    }
}

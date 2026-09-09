import Foundation

// MARK: - Google Calendar helpers

enum GCal {
    static let base = "https://www.googleapis.com/calendar/v3"
    static let icon = "calendar"
    static let group = "Calendar"
    static let source = "Google Calendar"

    struct CalendarInfo { var id: String; var name: String; var primary: Bool; var writable: Bool; var color: String?; var selected: Bool }

    static func calendars() async throws -> [CalendarInfo] {
        let r = try await GoogleAPI.json(.GET, "\(base)/users/me/calendarList", query: ["maxResults": 100, "minAccessRole": "reader"])
        let items = r["items"] as? [[String: Any]] ?? []
        return items.map { c in
            let role = c["accessRole"] as? String ?? "reader"
            return CalendarInfo(id: c["id"] as? String ?? "", name: c["summaryOverride"] as? String ?? c["summary"] as? String ?? "",
                                primary: (c["primary"] as? Bool) ?? false, writable: role == "owner" || role == "writer",
                                color: c["backgroundColor"] as? String, selected: (c["selected"] as? Bool) ?? true)
        }.filter { !$0.id.isEmpty }
    }

    /// Resolves an optional calendar name/id to ids. Nil → all selected calendars.
    static func resolve(_ nameOrId: String?, writableOnly: Bool = false) async throws -> [CalendarInfo] {
        let all = try await calendars()
        guard let n = nameOrId?.trimmingCharacters(in: .whitespaces), !n.isEmpty else {
            return all.filter { $0.selected && (!writableOnly || $0.writable) }
        }
        if n.lowercased() == "primary", let p = all.first(where: { $0.primary }) { return [p] }
        if let hit = all.first(where: { $0.id == n || $0.name.caseInsensitiveCompare(n) == .orderedSame }) { return [hit] }
        throw GoogleAPI.APIError(status: 404, message: "No calendar named '\(n)'. Available: \(all.map { $0.name }.joined(separator: ", "))")
    }

    struct Event {
        var id: String; var calendarId: String; var calendarName: String; var title: String; var location: String?
        var description: String?; var start: GoogleDates.Parsed; var end: GoogleDates.Parsed?; var allDay: Bool
        var meetingLink: String?; var attendees: [[String: Any]]; var htmlLink: String?; var status: String; var transparent: Bool; var recurring: Bool
        var json: [String: Any] {
            var j: [String: Any] = ["event_id": id, "calendar": calendarName, "calendar_id": calendarId, "title": title,
                                    "start": allDay ? GoogleDates.ymd(start.date) : GoogleDates.rfc3339(start.date),
                                    "start_human": allDay ? "\(GoogleDates.dayShort(start.date)) (all day)" : GoogleDates.human(start.date),
                                    "all_day": allDay]
            if let end { j["end"] = allDay ? GoogleDates.ymd(end.date) : GoogleDates.rfc3339(end.date) }
            if let location, !location.isEmpty { j["location"] = location }
            if let meetingLink { j["meeting_link"] = meetingLink }
            if !attendees.isEmpty { j["attendees"] = attendees }
            if let htmlLink { j["html_link"] = htmlLink }
            if let description, !description.isEmpty { j["description"] = String(description.prefix(400)) }
            if recurring { j["recurring"] = true }
            if status != "confirmed" { j["status"] = status }
            return j
        }
        var calendarColor: String? = nil
        var row: GlanceCard.Row {
            let when = allDay ? "All day" : GoogleDates.time(start.date) + (end.map { "\n\(GoogleDates.time($0.date))" } ?? "")
            var sub = GoogleDates.dayShort(start.date)
            if let location, !location.isEmpty { sub += " · \(location)" }
            return .init(title: title, subtitle: sub, icon: nil, trailing: when, tone: .neutral, url: meetingLink ?? htmlLink, accent: calendarColor)
        }
    }

    static func meetingLink(_ e: [String: Any]) -> String? {
        if let h = e["hangoutLink"] as? String, !h.isEmpty { return h }
        if let conf = e["conferenceData"] as? [String: Any], let eps = conf["entryPoints"] as? [[String: Any]] {
            if let v = eps.first(where: { ($0["entryPointType"] as? String) == "video" })?["uri"] as? String { return v }
            if let u = eps.first?["uri"] as? String { return u }
        }
        let text = [(e["location"] as? String), (e["description"] as? String)].compactMap { $0 }.joined(separator: "\n")
        if let r = text.range(of: #"https?://[^\s<>"']*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com)[^\s<>"']*"#, options: .regularExpression) {
            return String(text[r])
        }
        return nil
    }

    static func parse(_ e: [String: Any], calendar: CalendarInfo) -> Event? {
        guard var ev = parseRaw(e, calendar: calendar) else { return nil }
        ev.calendarColor = calendar.color
        return ev
    }
    private static func parseRaw(_ e: [String: Any], calendar: CalendarInfo) -> Event? {
        guard let id = e["id"] as? String, let start = GoogleDates.fromEventTime(e["start"] as? [String: Any]) else { return nil }
        let end = GoogleDates.fromEventTime(e["end"] as? [String: Any])
        let attendees = (e["attendees"] as? [[String: Any]] ?? []).compactMap { a -> [String: Any]? in
            guard let email = a["email"] as? String else { return nil }
            var j: [String: Any] = ["email": email]
            if let n = a["displayName"] as? String { j["name"] = n }
            if let s = a["responseStatus"] as? String { j["response"] = s }
            if (a["organizer"] as? Bool) == true { j["organizer"] = true }
            return j
        }
        return Event(id: id, calendarId: calendar.id, calendarName: calendar.name, title: e["summary"] as? String ?? "(no title)",
                     location: e["location"] as? String, description: e["description"] as? String, start: start, end: end, allDay: start.dateOnly,
                     meetingLink: meetingLink(e), attendees: attendees, htmlLink: e["htmlLink"] as? String, status: e["status"] as? String ?? "confirmed",
                     transparent: (e["transparency"] as? String) == "transparent", recurring: e["recurringEventId"] != nil || e["recurrence"] != nil)
    }

    static func events(in calendars: [CalendarInfo], from: Date, to: Date, q: String? = nil, perCalendar: Int = 100) async throws -> [Event] {
        try await withThrowingTaskGroup(of: [Event].self) { group in
            for c in calendars {
                group.addTask {
                    var query: [String: Any] = ["timeMin": GoogleDates.rfc3339(from), "timeMax": GoogleDates.rfc3339(to), "singleEvents": true,
                                                "orderBy": "startTime", "maxResults": perCalendar, "timeZone": GoogleDates.tzId]
                    if let q, !q.isEmpty { query["q"] = q }
                    let r = try await GoogleAPI.json(.GET, "\(base)/calendars/\(c.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? c.id)/events", query: query)
                    return (r["items"] as? [[String: Any]] ?? []).compactMap { parse($0, calendar: c) }.filter { $0.status != "cancelled" }
                }
            }
            var out: [Event] = []
            for try await evs in group { out += evs }
            return out.sorted { $0.start.date < $1.start.date }
        }
    }

    static func card(_ events: [Event], title: String, subtitle: String?) -> CardKind {
        var blocks: [GlanceCard.Block] = [.header(title: title, subtitle: subtitle, icon: icon)]
        if events.isEmpty { blocks.append(.text("Nothing scheduled.")) } else { blocks.append(.list(rows: events.prefix(6).map { $0.row })) }
        return .glance(GlanceCard(id: UUID(), blocks: blocks, source: source, sourceIcon: icon))
    }

    static func range(_ args: [String: Any], defaultDays: Int) -> (Date, Date)? {
        let start = GoogleDates.parse(GoogleAPI.trimmed(args["start"]))?.date ?? Date()
        let end: Date
        if let e = GoogleDates.parse(GoogleAPI.trimmed(args["end"])) {
            end = e.dateOnly ? Calendar.current.date(byAdding: .day, value: 1, to: e.date)! : e.date
        } else { end = Calendar.current.date(byAdding: .day, value: defaultDays, to: start)! }
        return end > start ? (start, end) : nil
    }

    static func timeObject(_ p: GoogleDates.Parsed, allDay: Bool) -> [String: Any] {
        allDay ? ["date": GoogleDates.ymd(p.date)] : ["dateTime": GoogleDates.rfc3339(p.date), "timeZone": GoogleDates.tzId]
    }
    static func encodedId(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s }
}

// MARK: - Tools

struct GCalListCalendars: Tool {
    let name = "gcal_list_calendars"
    let description = "Enumerates every Google Calendar on the account — the user's own such as 'Personal' or 'Work', plus anything shared with them — noting each one's colour, whether it can be written to, and which one counts as primary. Run it ahead of reading or creating events so you know what is actually there, above all when an event needs to land on a particular calendar."
    let params: [ToolParam] = []
    let statusLabel = "Listing calendars"
    let statusIcon = GCal.icon
    let group = GCal.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        await GoogleAPI.gated {
            let cals = try await GCal.calendars()
            let j = cals.map { c -> [String: Any] in
                var d: [String: Any] = ["id": c.id, "name": c.name, "writable": c.writable, "primary": c.primary]
                if let col = c.color { d["color"] = col }
                return d
            }
            let card = CardKind.glance(GlanceCard(id: UUID(), blocks: [
                .header(title: "Calendars", subtitle: "\(cals.count) calendars", icon: GCal.icon),
                .list(rows: cals.prefix(6).map { .init(title: $0.name, subtitle: $0.primary ? "Primary" : ($0.writable ? "Writable" : "Read only"), icon: nil, trailing: nil) }),
            ], source: GCal.source, sourceIcon: GCal.icon))
            return .ok(["ok": true, "calendars": j], cards: [card])
        }
    }
}

struct GCalListEvents: Tool {
    let name = "gcal_list_events"
    let description = "Returns what is coming up across the user's Google Calendars between two dates. Every entry carries the calendar it sits on, its title, where it happens, when it starts and ends, who is invited, and the event_id that updating or deleting requires; events with a video call also carry meeting_link, the join address for Meet, Zoom, Teams or whatever else. Hand back that meeting_link whenever someone asks how to join or what the link is. This is what answers 'what's on my calendar this week?' and 'am I free Friday afternoon?'. Absent a range, it looks a week ahead."
    let params = [
        ToolParam("start", "string", "Where the range begins, as an ISO 8601 date or full timestamp — '2026-06-20' for example. The present moment is used if this is absent."),
        ToolParam("end", "string", "Where the range stops, as an ISO 8601 date or full timestamp. Left out, it sits a week past the start. Giving a plain date pulls in the entirety of that day."),
        ToolParam("calendar", "string", "One calendar's name, spelled precisely as gcal_list_calendars gave it; guessing a name is never acceptable. Usually this is left empty, which covers all of them."),
    ]
    let statusLabel = "Reading calendar"
    let statusIcon = GCal.icon
    let group = GCal.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        await GoogleAPI.gated {
            guard let (from, to) = GCal.range(args, defaultDays: 7) else { return .fail("end must be after start.") }
            let cals = try await GCal.resolve(GoogleAPI.trimmed(args["calendar"]))
            let evs = Array(try await GCal.events(in: cals, from: from, to: to).prefix(50))
            let f = DateFormatter(); f.dateFormat = "MMM d"
            return .ok(["ok": true, "range": "\(GoogleDates.human(from)) → \(GoogleDates.human(to))", "count": evs.count, "events": evs.map { $0.json }],
                       cards: [GCal.card(evs, title: "Upcoming", subtitle: "\(f.string(from: from)) – \(f.string(from: to))")])
        }
    }
}

struct GCalSearchEvents: Tool {
    let name = "gcal_search_events"
    let description = "Looks for a phrase anywhere in an event's title, location, notes or guest list. Matches come back with their event_id, the calendar they belong to, title, location, start and end times, and — where a video call is attached — meeting_link, the join address for Meet, Zoom, Teams and the like; pass that link along when the user asks for it. It handles 'find my meeting with Kai', 'when is my dentist appointment?' and 'what's the link for my 4pm?'. The default window is the coming month."
    let params = [
        ToolParam("query", "string", "Words to look for in the event title, location, description or attendees.", required: true),
        ToolParam("start", "string", "Where searching begins, given as an ISO 8601 date or timestamp; the current moment applies by default."),
        ToolParam("end", "string", "Where searching stops. With nothing supplied it falls a month past the start."),
        ToolParam("calendar", "string", "Optional. A calendar's name written exactly as gcal_list_calendars gave it. Empty means every calendar is searched."),
    ]
    let statusLabel = "Searching calendar"
    let statusIcon = GCal.icon
    let group = GCal.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        await GoogleAPI.gated {
            guard let q = GoogleAPI.trimmed(args["query"]) else { return .fail("query is required.") }
            guard let (from, to) = GCal.range(args, defaultDays: 30) else { return .fail("end must be after start.") }
            let cals = try await GCal.resolve(GoogleAPI.trimmed(args["calendar"]))
            let evs = Array(try await GCal.events(in: cals, from: from, to: to, q: q).prefix(30))
            return .ok(["ok": true, "query": q, "count": evs.count, "events": evs.map { $0.json }],
                       cards: [GCal.card(evs, title: "Events", subtitle: "matching “\(q)”")])
        }
    }
}

struct GCalFindFreeSlots: Tool {
    let name = "gcal_find_free_slots"
    let description = "Works out when the user is FREE — the stretches with nothing booked — so something can be scheduled. Across the date range you give, it reports every unclaimed gap that reaches at least the length you ask for, staying inside working hours and taking all writable calendars into account. Behind requests such as 'find a 30-minute slot tomorrow', 'when am I next free for an hour?' and 'am I free Friday afternoon?'. Once a gap is chosen, gcal_create_event actually books it. Anything all-day, and anything the user has themselves marked FREE, does NOT count as busy."
    let params = [
        ToolParam("start", "string", "Where searching begins, given as an ISO 8601 date or timestamp; the current moment applies by default."),
        ToolParam("end", "string", "Where searching stops, as an ISO 8601 date or timestamp. Absent, it lands a week past the start; a plain date takes in that entire day."),
        ToolParam("duration_minutes", "integer", "Minimum slot length in minutes. Default 30."),
        ToolParam("day_start_hour", "integer", "Earliest hour of day to consider, 0–23 (default 9 for 9am)."),
        ToolParam("day_end_hour", "integer", "The last hour that may be used, from 1 to 24, defaulting to 18 which is 6pm. To treat a request as an evening one, try pairing day_start_hour 17 with day_end_hour 22."),
        ToolParam("calendar", "string", "Optional. A calendar's name spelled precisely as gcal_list_calendars gave it — never invent one. Empty means every writable calendar counts."),
    ]
    let statusLabel = "Finding free time"
    let statusIcon = GCal.icon
    let group = GCal.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        await GoogleAPI.gated {
            guard let (from, to) = GCal.range(args, defaultDays: 7) else { return .fail("end must be after start.") }
            let duration = TimeInterval(GoogleAPI.int(args["duration_minutes"], default: 30) * 60)
            let dayStart = min(23, Swift.max(0, GoogleAPI.int(args["day_start_hour"], default: 9) - 1 + 1))
            let dayEnd = min(24, Swift.max(1, GoogleAPI.int(args["day_end_hour"], default: 18)))
            guard dayEnd > dayStart else { return .fail("day_end_hour must be after day_start_hour.") }
            let cals = try await GCal.resolve(GoogleAPI.trimmed(args["calendar"]), writableOnly: true)
            let busy = try await GCal.events(in: cals, from: from, to: to, perCalendar: 250)
                .filter { !$0.allDay && !$0.transparent && $0.end != nil }
                .map { ($0.start.date, $0.end!.date) }
                .sorted { $0.0 < $1.0 }
            var slots: [[String: Any]] = []
            var rows: [GlanceCard.Row] = []
            let cal = Calendar.current
            var day = cal.startOfDay(for: from)
            while day < to, slots.count < 20 {
                let windowStart = Swift.max(cal.date(bySettingHour: dayStart, minute: 0, second: 0, of: day)!, from)
                let windowEnd = min(dayEnd == 24 ? cal.date(byAdding: .day, value: 1, to: day)! : cal.date(bySettingHour: dayEnd, minute: 0, second: 0, of: day)!, to)
                var cursor = windowStart
                if cursor < windowEnd {
                    for (s, e) in busy where e > windowStart && s < windowEnd {
                        if s > cursor, s.timeIntervalSince(cursor) >= duration { append(cursor, s) }
                        cursor = Swift.max(cursor, e)
                    }
                    if windowEnd.timeIntervalSince(cursor) >= duration { append(cursor, windowEnd) }
                }
                day = cal.date(byAdding: .day, value: 1, to: day)!
            }
            func append(_ s: Date, _ e: Date) {
                guard slots.count < 20 else { return }
                slots.append(["start": GoogleDates.rfc3339(s), "end": GoogleDates.rfc3339(e), "human": "\(GoogleDates.human(s))–\(GoogleDates.time(e))", "minutes": Int(e.timeIntervalSince(s) / 60)])
                rows.append(.init(title: "\(GoogleDates.time(s)) – \(GoogleDates.time(e))", subtitle: "\(Int(e.timeIntervalSince(s) / 60)) min free", icon: nil, trailing: GoogleDates.dayShort(s), tone: .good))
            }
            var blocks: [GlanceCard.Block] = [.header(title: "Free slots", subtitle: "≥ \(Int(duration / 60)) min, \(dayStart):00–\(dayEnd):00", icon: GCal.icon)]
            blocks.append(rows.isEmpty ? .text("No free slots in that window.") : .list(rows: Array(rows.prefix(6))))
            return .ok(["ok": true, "duration_minutes": Int(duration / 60), "count": slots.count, "slots": slots],
                       cards: [.glance(GlanceCard(id: UUID(), blocks: blocks, source: GCal.source, sourceIcon: GCal.icon))])
        }
    }
}

struct GCalCreateEvent: Tool {
    let name = "gcal_create_event"
    let description = "Puts a new entry on Google Calendar. A title and a starting date or time are required; everything else is optional — an ending time, which otherwise falls an hour later, a location, some notes, email addresses of guests who then get invited, and a flag for all-day. It covers 'put dentist on my calendar Friday' and 'schedule a meeting with Kai tomorrow at 3pm'. Turn anything relative — 'tomorrow', 'next Tuesday' — into a definite ISO 8601 value by reckoning from today's date. To CHANGE it later, extra guests included, use gcal_update_event addressed by this event's event_id; deleting and rebuilding it is the wrong approach. Leave `calendar` out and the entry lands on their primary calendar; pass it ONLY when the user named a calendar and gcal_list_calendars confirms that name exists."
    let params = [
        ToolParam("title", "string", "Event title.", required: true),
        ToolParam("start_datetime", "string", "When it begins, written as a local ISO 8601 value such as '2026-06-20T15:00:00'. Where the entry runs all day, a plain date like '2026-06-20' suffices.", required: true),
        ToolParam("end_datetime", "string", "Optional. When it finishes, as a local ISO 8601 value. Timed entries that omit it simply run for an hour."),
        ToolParam("location", "string", "Optional location text."),
        ToolParam("description", "string", "Optional notes/description."),
        ToolParam("attendees", "array", "Optional. Email addresses of people to put on the guest list, as in ['kai@example.com']; each of them is sent an invitation.", items: "string"),
        ToolParam("all_day", "boolean", "True marks the entry as spanning the whole day. Unset, it is false and the entry is a timed one."),
        ToolParam("add_meet", "boolean", "True adds a Google Meet call to the entry. It is off unless set."),
        ToolParam("calendar", "string", "Leave this out altogether unless the user actually named a calendar and gcal_list_calendars has handed you its exact name; names are never to be guessed. With nothing here, the entry goes on the primary calendar."),
    ]
    let confirmation: ConfirmationSpec? = ConfirmationSpec(
        icon: "calendar.badge.plus", title: "Create event",
        subtitle: { a in JSON.string(a["title"]) },
        fields: [("title", "Title", .text, true), ("start_datetime", "Start", .datetime, true), ("end_datetime", "End", .datetime, false),
                 ("all_day", "All day", .toggle, false), ("location", "Location", .text, false), ("attendees", "Attendees", .text, false),
                 ("calendar", "Calendar", .text, false)],
        confirmLabel: "Save", layout: .event)
    let statusLabel = "Creating event"
    let statusIcon = "calendar.badge.plus"
    let group = GCal.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        await GoogleAPI.gated {
            guard let title = GoogleAPI.trimmed(args["title"]) else { return .fail("title is required.") }
            guard let start = GoogleDates.parse(GoogleAPI.trimmed(args["start_datetime"])) else { return .fail("start_datetime is missing or not ISO 8601.", guidance: "Use e.g. 2026-06-20T15:00:00 or 2026-06-20 for all-day.") }
            let allDay = GoogleAPI.bool(args["all_day"]) || start.dateOnly
            var end = GoogleDates.parse(GoogleAPI.trimmed(args["end_datetime"]))
            if end == nil { end = GoogleDates.Parsed(date: allDay ? Calendar.current.date(byAdding: .day, value: 1, to: start.date)! : start.date.addingTimeInterval(3600), dateOnly: allDay) }
            else if allDay, end!.dateOnly { end!.date = Calendar.current.date(byAdding: .day, value: 1, to: end!.date)! }  // Google end date is exclusive
            guard end!.date > start.date else { return .fail("end_datetime must be after start_datetime.") }
            let attendees = GoogleAPI.strings(args["attendees"])
            guard Gmail.validEmails(attendees) != nil else { return .fail("An attendee address is not a valid email: \(attendees)") }
            var body: [String: Any] = ["summary": title, "start": GCal.timeObject(start, allDay: allDay), "end": GCal.timeObject(end!, allDay: allDay)]
            if let l = GoogleAPI.trimmed(args["location"]) { body["location"] = l }
            if let d = GoogleAPI.trimmed(args["description"]) { body["description"] = d }
            if !attendees.isEmpty { body["attendees"] = attendees.map { ["email": $0] } }
            var query: [String: Any] = [:]
            if !attendees.isEmpty { query["sendUpdates"] = "all" }
            if GoogleAPI.bool(args["add_meet"]) {
                body["conferenceData"] = ["createRequest": ["requestId": UUID().uuidString, "conferenceSolutionKey": ["type": "hangoutsMeet"]]]
                query["conferenceDataVersion"] = 1
            }
            let cal = try await GCal.resolve(GoogleAPI.trimmed(args["calendar"]) ?? "primary", writableOnly: true).first!
            let r = try await GoogleAPI.json(.POST, "\(GCal.base)/calendars/\(GCal.encodedId(cal.id))/events", query: query, jsonBody: body)
            guard let ev = GCal.parse(r, calendar: cal) else { return .fail("Google created the event but returned an unexpected response.") }
            return .ok(["ok": true, "event_id": ev.id, "html_link": ev.htmlLink ?? "", "calendar": cal.name, "event": ev.json],
                       cards: [GCal.card([ev], title: "Event created", subtitle: cal.name)])
        }
    }
}

struct GCalUpdateEvent: Tool {
    let name = "gcal_update_event"
    let description = "Alters an entry that already exists without replacing it, whether that means a different title, a different time, a new location or notes, or additional guests. Any time the user adjusts something they or you just made or looked up — 'rename it', 'add Kai to that', 'push it to 4pm', 'change where it is' — ALWAYS prefer this to deleting and rebuilding. Give it the event_id returned by gcal_create_event, gcal_list_events or gcal_search_events. Pass the entry's present title too, and its start_datetime where you know it, so the confirmation makes plain which entry is being touched. Fill in only the fields that are genuinely changing."
    let params = [
        ToolParam("event_id", "string", "The exact event_id of the event to modify (from gcal_create_event / gcal_list_events / gcal_search_events).", required: true),
        ToolParam("calendar_id", "string", "The calendar_id the event lives on, from the same result. Omit to use the primary calendar."),
        ToolParam("title", "string", "A replacement title. Even when it is not changing, send the existing one so the confirmation can name the entry."),
        ToolParam("start_datetime", "string", "A replacement starting point, as a local ISO 8601 value like '2026-06-20T16:00:00'. Leaving it out preserves the present start."),
        ToolParam("end_datetime", "string", "A replacement finishing point, as a local ISO 8601 value. Omitting it preserves the present end, so shifting only the start leaves the entry the same length."),
        ToolParam("location", "string", "New location. Omit to keep it."),
        ToolParam("description", "string", "New description/notes. Omit to keep it."),
        ToolParam("add_attendees", "array", "Addresses to append to the guest list while everyone already on it stays. This is strictly for adding somebody on top; swapping or dropping a guest is set_attendees' job.", items: "string"),
        ToolParam("set_attendees", "array", "The guest list in full as it should end up, overwriting whoever is on it now. Use it to swap somebody out or drop them, and pass an empty array to clear the list entirely. Wherever the user talks about changing, fixing, replacing or removing a guest, this is the field rather than add_attendees.", items: "string"),
        ToolParam("all_day", "boolean", "Pass true or false to switch the entry between all-day and timed. Nothing here means the current setting stands."),
    ]
    let confirmation: ConfirmationSpec? = ConfirmationSpec(
        icon: "calendar.badge.clock", title: "Update event",
        subtitle: { a in JSON.string(a["title"]) },
        fields: [("title", "Title", .text, false), ("start_datetime", "Start", .datetime, false), ("end_datetime", "End", .datetime, false),
                 ("all_day", "All day", .toggle, false), ("location", "Location", .text, false), ("add_attendees", "Add attendees", .text, false)],
        confirmLabel: "Save", layout: .event)
    let statusLabel = "Updating event"
    let statusIcon = "calendar.badge.clock"
    let group = GCal.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        await GoogleAPI.gated {
            guard let id = GoogleAPI.trimmed(args["event_id"]) else { return .fail("event_id is required.") }
            let cal = try await GCal.resolve(GoogleAPI.trimmed(args["calendar_id"]) ?? "primary").first!
            let path = "\(GCal.base)/calendars/\(GCal.encodedId(cal.id))/events/\(GCal.encodedId(id))"
            let current = try await GoogleAPI.json(.GET, path)
            guard let cur = GCal.parse(current, calendar: cal) else { return .fail("Event \(id) not found on \(cal.name).", guidance: "Look it up again with gcal_list_events or gcal_search_events.") }
            var patch: [String: Any] = [:]
            if let t = GoogleAPI.trimmed(args["title"]), t != cur.title { patch["summary"] = t }
            if let l = JSON.string(args["location"]) { patch["location"] = l }
            if let d = JSON.string(args["description"]) { patch["description"] = d }
            let allDay = args["all_day"] == nil ? cur.allDay : GoogleAPI.bool(args["all_day"])
            let newStart = GoogleDates.parse(GoogleAPI.trimmed(args["start_datetime"]))
            let newEnd = GoogleDates.parse(GoogleAPI.trimmed(args["end_datetime"]))
            if newStart != nil || newEnd != nil || allDay != cur.allDay {
                let s = newStart ?? cur.start
                var e: GoogleDates.Parsed
                if let newEnd { e = newEnd; if allDay, e.dateOnly { e.date = Calendar.current.date(byAdding: .day, value: 1, to: e.date)! } }
                else if let newStart, let curEnd = cur.end { e = GoogleDates.Parsed(date: newStart.date.addingTimeInterval(curEnd.date.timeIntervalSince(cur.start.date)), dateOnly: allDay) }
                else if let curEnd = cur.end { e = curEnd }
                else { e = GoogleDates.Parsed(date: s.date.addingTimeInterval(allDay ? 86400 : 3600), dateOnly: allDay) }
                guard e.date > s.date else { return .fail("end_datetime must be after start_datetime.") }
                patch["start"] = GCal.timeObject(s, allDay: allDay)
                patch["end"] = GCal.timeObject(e, allDay: allDay)
            }
            var query: [String: Any] = [:]
            if args["set_attendees"] != nil {
                let list = GoogleAPI.strings(args["set_attendees"])
                guard Gmail.validEmails(list) != nil else { return .fail("An attendee address is not a valid email: \(list)") }
                patch["attendees"] = list.map { ["email": $0] }; query["sendUpdates"] = "all"
            } else {
                let add = GoogleAPI.strings(args["add_attendees"])
                if !add.isEmpty {
                    guard Gmail.validEmails(add) != nil else { return .fail("An attendee address is not a valid email: \(add)") }
                    var existing = (current["attendees"] as? [[String: Any]] ?? [])
                    let have = Set(existing.compactMap { ($0["email"] as? String)?.lowercased() })
                    for a in add where !have.contains(a.lowercased()) { existing.append(["email": a]) }
                    patch["attendees"] = existing; query["sendUpdates"] = "all"
                }
            }
            guard !patch.isEmpty else { return .fail("Nothing to change.", guidance: "Pass at least one field that differs from the current event.") }
            let r = try await GoogleAPI.json(.PATCH, path, query: query, jsonBody: patch)
            guard let ev = GCal.parse(r, calendar: cal) else { return .fail("Google updated the event but returned an unexpected response.") }
            return .ok(["ok": true, "event_id": ev.id, "html_link": ev.htmlLink ?? "", "changed": Array(patch.keys).sorted(), "event": ev.json],
                       cards: [GCal.card([ev], title: "Event updated", subtitle: cal.name)])
        }
    }
}

struct GCalDeleteEvent: Tool {
    let name = "gcal_delete_event"
    let description = "Removes an entry from Google Calendar completely. Reserve it for cases where the user genuinely wants something cancelled or taken off, NOT for altering it: adjusting a time, title, location or guest list is gcal_update_event's work, and deleting in order to rebuild is always wrong. Supply the precise event_id from gcal_list_events or gcal_search_events along with the entry's title, so the confirmation names what is going. It serves 'cancel my 3pm' and 'delete the dentist event' — look the entry up first to obtain its event_id."
    let params = [
        ToolParam("event_id", "string", "The exact event_id from gcal_list_events / gcal_search_events / gcal_create_event.", required: true),
        ToolParam("calendar_id", "string", "The calendar_id from the same result. Omit to use the primary calendar."),
        ToolParam("title", "string", "The event's title, copied from the lookup result, so the confirmation shows what is being deleted."),
        ToolParam("notify_attendees", "boolean", "Send cancellation emails to attendees. Default true."),
    ]
    let confirmation: ConfirmationSpec? = ConfirmationSpec(
        icon: "calendar.badge.minus", title: "Delete event",
        subtitle: { a in JSON.string(a["title"]) },
        fields: [("title", "Event", .text, false)],
        confirmLabel: "Delete", destructive: true)
    let statusLabel = "Deleting event"
    let statusIcon = "calendar.badge.minus"
    let group = GCal.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        await GoogleAPI.gated {
            guard let id = GoogleAPI.trimmed(args["event_id"]) else { return .fail("event_id is required.") }
            let cal = try await GCal.resolve(GoogleAPI.trimmed(args["calendar_id"]) ?? "primary").first!
            let notify = args["notify_attendees"] == nil ? true : GoogleAPI.bool(args["notify_attendees"])
            _ = try await GoogleAPI.request(.DELETE, "\(GCal.base)/calendars/\(GCal.encodedId(cal.id))/events/\(GCal.encodedId(id))", query: ["sendUpdates": notify ? "all" : "none"])
            return .ok(["ok": true, "event_id": id, "deleted": true, "calendar": cal.name])
        }
    }
}

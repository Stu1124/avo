import AppKit
import Foundation

/// Every Apple-native tool Avo registers: iMessage, Reminders (EventKit + local timed), Finder, Apps, Spotify.
enum AppleTools {
    static func all() -> [Tool] {
        let tools: [Tool] = IMessageTools.all() + RemindersTools.all() + LocalReminderTools.all()
            + FinderTools.all() + AppTools.all() + SpotifyTools.all()
        Log.info("AppleTools: \(tools.count) tools (\(tools.map(\.name).joined(separator: ", ")))")
        return tools
    }

    /// Default Apple Reminders list without touching the main-actor Settings object.
    /// Empty — the default — means the list Reminders itself treats as the default.
    nonisolated static var defaultReminderList: String {
        UserDefaults.standard.string(forKey: "defaultReminderList") ?? ""
    }
}

/// Date parsing and formatting shared by the Apple tools.
enum HDate {
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let localFormats = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd h:mm a"]

    /// ISO 8601 (with or without offset/fractional seconds), `yyyy-MM-dd[ HH:mm]`, or natural language ("tomorrow at 9am").
    static func parse(_ raw: String, defaultHour: Int = 9) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let d = isoFrac.date(from: s) ?? isoPlain.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for p in localFormats { f.dateFormat = p; if let d = f.date(from: s) { return d } }
        f.dateFormat = "yyyy-MM-dd"
        if let d = f.date(from: s) { return Calendar.current.date(bySettingHour: defaultHour, minute: 0, second: 0, of: d) }
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let m = det.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let d = m.date {
            return d
        }
        return nil
    }

    /// ISO 8601 with the local offset, e.g. 2026-07-18T17:00:00-07:00.
    static func iso(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return f.string(from: d)
    }

    /// "Today 5:00 PM", "Tomorrow 9:00 AM", "Wed 3:15 PM", "Jun 3, 2:00 PM".
    static func human(_ d: Date) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return "Today \(time)" }
        if cal.isDateInTomorrow(d) { return "Tomorrow \(time)" }
        if cal.isDateInYesterday(d) { return "Yesterday \(time)" }
        let days = abs(cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 99)
        let f = DateFormatter()
        f.locale = .current
        let sameYear = cal.component(.year, from: d) == cal.component(.year, from: Date())
        f.dateFormat = days < 7 ? "EEE" : (sameYear ? "MMM d" : "MMM d, yyyy")
        return "\(f.string(from: d)) \(time)"
    }

    /// Date only: "Today", "Tomorrow", "Wed", "Jun 3".
    static func humanDay(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let days = abs(cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 99)
        let f = DateFormatter()
        f.locale = .current
        let sameYear = cal.component(.year, from: d) == cal.component(.year, from: Date())
        f.dateFormat = days < 7 ? "EEE" : (sameYear ? "MMM d" : "MMM d, yyyy")
        return f.string(from: d)
    }

    /// Compact relative time for card trailing text: "now", "5m", "3h", "Yesterday", "Mon", "Jun 3".
    static func relative(_ d: Date) -> String {
        let cal = Calendar.current
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if cal.isDateInToday(d) { return "\(Int(s / 3600))h" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let days = abs(cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 99)
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = days < 7 ? "EEE" : "MMM d"
        return f.string(from: d)
    }

    /// Countdown text: "in 10 min", "in 2 h 5 min", "in 3 days".
    static func countdown(to d: Date) -> String {
        let s = d.timeIntervalSinceNow
        if s < 0 { return "overdue" }
        let m = Int((s / 60).rounded())
        if m < 1 { return "now" }
        if m < 60 { return "in \(m) min" }
        if m < 24 * 60 { let h = m / 60; let r = m % 60; return r == 0 ? "in \(h) h" : "in \(h) h \(r) min" }
        let days = Int((s / 86400).rounded())
        return "in \(days) day\(days == 1 ? "" : "s")"
    }
}

/// Card builders shared by the Apple tools.
enum Cards {
    static func glance(source: String, icon: String, header: (title: String, subtitle: String?)? = nil, rows: [GlanceCard.Row] = [], text: String? = nil) -> CardKind {
        var blocks: [GlanceCard.Block] = []
        if let h = header { blocks.append(.header(title: h.title, subtitle: h.subtitle, icon: icon)) }
        if !rows.isEmpty { blocks.append(.list(rows: Array(rows.prefix(6)))) }
        if let t = text, !t.isEmpty { blocks.append(.text(t)) }
        return .glance(GlanceCard(id: UUID(), blocks: blocks, source: source, sourceIcon: icon))
    }

    static func note(source: String, icon: String, title: String, body: String) -> CardKind {
        .glance(GlanceCard(id: UUID(), blocks: [.header(title: title, subtitle: nil, icon: icon), .text(body)], source: source, sourceIcon: icon))
    }
}

extension String {
    /// Collapse whitespace and cut to `n` characters for previews.
    func preview(_ n: Int = 90) -> String {
        let one = self.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if one.count <= n { return one }
        return String(one.prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    var expandingTilde: String {
        let t = self.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("~") { return (t as NSString).expandingTildeInPath }
        if t.hasPrefix("/") { return t }
        if t.hasPrefix("file://"), let u = URL(string: t) { return u.path }
        return Paths.home.appendingPathComponent(t).path
    }
}

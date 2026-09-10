import SwiftUI

// MARK: - ISO plumbing shared by the date/time fields

enum ScheduleISO {
    /// Reads any ISO 8601 form the tools accept (bare date, local datetime, datetime with offset).
    static func parse(_ s: String) -> (date: Date, allDay: Bool)? {
        guard let p = GoogleDates.parse(s) else { return nil }
        return (p.date, p.dateOnly)
    }
    /// Writes a bare date for all-day values, otherwise a local datetime with the zone offset.
    static func string(_ d: Date, allDay: Bool) -> String {
        if allDay { return GoogleDates.ymd(d) }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return f.string(from: d)
    }
    static func roundedSoon() -> Date {
        let cal = Calendar.current
        let now = Date()
        let m = cal.component(.minute, from: now)
        let add = 30 - (m % 30)
        return cal.date(byAdding: .minute, value: add, to: cal.date(bySetting: .second, value: 0, of: now) ?? now) ?? now
    }
    static func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        let f = DateFormatter(); f.timeZone = .current
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "EEE, MMM d" : "EEE, MMM d, yyyy"
        return f.string(from: d)
    }
    static func timeLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.timeZone = .current; f.dateFormat = "h:mm a"
        return f.string(from: d).replacingOccurrences(of: ":00", with: "")
    }
    static func durationLabel(_ secs: TimeInterval) -> String {
        let m = Int(secs.rounded() / 60)
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        if r == 0 { return h == 1 ? "1 hr" : "\(h) hr" }
        return "\(h) hr \(r) min"
    }
    /// Keeps the time-of-day of `time` on the calendar day of `day`.
    static func combine(day: Date, time: Date) -> Date {
        let cal = Calendar.current
        let t = cal.dateComponents([.hour, .minute], from: time)
        return cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0, of: day) ?? day
    }
}

// MARK: - Start/end editor (Google Calendar style) for event confirmations

/// Two rows (Starts / Ends) of date + time chips that expand inline into a month grid or a time grid,
/// an all-day switch, and duration shortcuts. Binds to the ISO strings the calendar tools read.
struct EventScheduleEditor: View {
    @Binding var startISO: String
    @Binding var endISO: String
    @Binding var allDayISO: String

    private enum Expanded { case none, startDate, startTime, endDate, endTime }
    @State private var expanded: Expanded = .none
    @State private var start: Date
    @State private var end: Date
    @State private var allDay: Bool

    init(startISO: Binding<String>, endISO: Binding<String>, allDayISO: Binding<String>) {
        _startISO = startISO; _endISO = endISO; _allDayISO = allDayISO
        let s = ScheduleISO.parse(startISO.wrappedValue)
        let e = ScheduleISO.parse(endISO.wrappedValue)
        let sd = s?.date ?? ScheduleISO.roundedSoon()
        let ad = (allDayISO.wrappedValue as NSString).boolValue || (s?.allDay ?? false)
        _start = State(initialValue: sd)
        _end = State(initialValue: (e?.date).flatMap { $0 > sd ? $0 : nil } ?? (ad ? sd : sd.addingTimeInterval(3600)))
        _allDay = State(initialValue: ad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WHEN").font(Theme.text(10, .semibold)).foregroundStyle(Theme.ink3).tracking(0.6)
                Spacer()
                Button { allDay.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: allDay ? "checkmark.circle.fill" : "circle").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(allDay ? Theme.accent : Theme.ink3)
                        Text("All day").font(Theme.text(12, .medium)).foregroundStyle(allDay ? Theme.ink : Theme.ink2)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(allDay ? Theme.accent.opacity(0.16) : Theme.fill1, in: Capsule())
                    .overlay(Capsule().strokeBorder(allDay ? Theme.accent.opacity(0.6) : Theme.line, lineWidth: 0.8))
                }.buttonStyle(.plain)
            }
            row(label: "Starts", date: start, dateOpen: .startDate, timeOpen: .startTime)
            if expanded == .startDate { MonthGrid(selected: Binding(get: { start }, set: { setStartDay($0) })) }
            if expanded == .startTime { TimeGrid(selected: Binding(get: { start }, set: { setStart($0) })) }
            row(label: "Ends", date: end, dateOpen: .endDate, timeOpen: .endTime)
            if expanded == .endDate { MonthGrid(selected: Binding(get: { end }, set: { setEnd(ScheduleISO.combine(day: $0, time: end)) })) }
            if expanded == .endTime { TimeGrid(selected: Binding(get: { end }, set: { setEnd($0) })) }
            if !allDay { durationPills }
        }
        .animation(Theme.springQuick, value: expanded)
        .animation(Theme.springQuick, value: allDay)
        .onAppear { write() }
        .onChange(of: allDay) { _, on in
            if on, expanded == .startTime || expanded == .endTime { expanded = .none }
            if !on, Calendar.current.isDate(start, inSameDayAs: end) && end <= start { end = start.addingTimeInterval(3600) }
            write()
        }
    }

    private func row(label: String, date: Date, dateOpen: Expanded, timeOpen: Expanded) -> some View {
        HStack(spacing: 6) {
            Text(label).font(Theme.text(12)).foregroundStyle(Theme.ink2).frame(width: 44, alignment: .leading)
            Chip(text: ScheduleISO.dayLabel(date), icon: "calendar", active: expanded == dateOpen) { toggle(dateOpen) }
            if !allDay {
                Chip(text: ScheduleISO.timeLabel(date), icon: "clock", active: expanded == timeOpen) { toggle(timeOpen) }
            }
            Spacer(minLength: 0)
            if label == "Ends", !allDay {
                Text(ScheduleISO.durationLabel(end.timeIntervalSince(start))).font(Theme.text(11)).foregroundStyle(Theme.ink3)
            }
        }
    }

    private var durationPills: some View {
        HStack(spacing: 5) {
            ForEach([15, 30, 45, 60, 90, 120], id: \.self) { m in
                let secs = TimeInterval(m * 60)
                let on = abs(end.timeIntervalSince(start) - secs) < 1
                Button { setEnd(start.addingTimeInterval(secs)) } label: {
                    Text(ScheduleISO.durationLabel(secs).replacingOccurrences(of: " min", with: "m").replacingOccurrences(of: " hr", with: "h").replacingOccurrences(of: " ", with: ""))
                        .font(Theme.text(11, .medium))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(on ? Theme.accent.opacity(0.28) : Theme.fill1, in: Capsule())
                        .foregroundStyle(on ? Theme.ink : Theme.ink2)
                        .overlay(Capsule().strokeBorder(on ? Theme.accent.opacity(0.6) : Theme.line, lineWidth: 0.8))
                }.buttonStyle(.plain)
            }
        }
    }

    private func toggle(_ e: Expanded) { expanded = expanded == e ? .none : e }

    private func setStartDay(_ day: Date) {
        setStart(ScheduleISO.combine(day: day, time: start))
        expanded = .none
    }
    private func setStart(_ d: Date) {
        let duration = max(end.timeIntervalSince(start), allDay ? 0 : 900)
        start = d
        end = d.addingTimeInterval(duration)
        write()
    }
    private func setEnd(_ d: Date) {
        end = allDay ? max(d, start) : (d > start ? d : start.addingTimeInterval(900))
        if expanded == .endDate { expanded = .none }
        write()
    }
    private func write() {
        startISO = ScheduleISO.string(start, allDay: allDay)
        endISO = ScheduleISO.string(end, allDay: allDay)
        allDayISO = allDay ? "true" : "false"
    }
}

/// Single date-time field (reminders, scheduled actions): date chip + time chip with the same expanders.
struct DateTimeField: View {
    @Binding var iso: String
    private enum Expanded { case none, date, time }
    @State private var expanded: Expanded = .none
    @State private var date: Date

    init(iso: Binding<String>) {
        _iso = iso
        _date = State(initialValue: ScheduleISO.parse(iso.wrappedValue)?.date ?? ScheduleISO.roundedSoon())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Chip(text: ScheduleISO.dayLabel(date), icon: "calendar", active: expanded == .date) { expanded = expanded == .date ? .none : .date }
                Chip(text: ScheduleISO.timeLabel(date), icon: "clock", active: expanded == .time) { expanded = expanded == .time ? .none : .time }
                Spacer(minLength: 0)
            }
            if expanded == .date {
                MonthGrid(selected: Binding(get: { date }, set: { date = ScheduleISO.combine(day: $0, time: date); expanded = .none; write() }))
            }
            if expanded == .time {
                TimeGrid(selected: Binding(get: { date }, set: { date = $0; write() }))
            }
        }
        .animation(Theme.springQuick, value: expanded)
        // Only normalise a value that is already there. Writing unconditionally stamped
        // `roundedSoon()` into an optional datetime the user had deliberately left blank — a
        // reminder with no due date came back from the card with one, chosen by nobody.
        .onAppear { if !iso.trimmingCharacters(in: .whitespaces).isEmpty { write() } }
    }
    private func write() { iso = ScheduleISO.string(date, allDay: false) }
}

// MARK: - Pieces

private struct Chip: View {
    var text: String; var icon: String; var active: Bool; var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(active ? Theme.accent : Theme.ink3)
                Text(text).font(Theme.text(13, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(active ? Theme.accent.opacity(0.16) : Theme.fill2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(active ? Theme.accent.opacity(0.6) : Theme.line, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }
}

/// A month at a time. Click a day to pick it; arrows page months; the dot marks today.
struct MonthGrid: View {
    @Binding var selected: Date
    @State private var visible: Date
    private let cal = Calendar.current

    init(selected: Binding<Date>) {
        _selected = selected
        _visible = State(initialValue: selected.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button { page(-1) } label: { Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 22) }
                    .buttonStyle(.plain).foregroundStyle(Theme.ink2)
                Spacer()
                Text(monthTitle).font(Theme.text(13, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Button { page(1) } label: { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 22) }
                    .buttonStyle(.plain).foregroundStyle(Theme.ink2)
            }
            let cols = Array(repeating: GridItem(.fixed(32), spacing: 2), count: 7)
            LazyVGrid(columns: cols, spacing: 2) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, w in
                    Text(w).font(Theme.text(10, .semibold)).foregroundStyle(Theme.ink3).frame(height: 18)
                }
                ForEach(days, id: \.self) { d in
                    dayCell(d)
                }
            }
        }
        .padding(10)
        .background(Theme.fill1, in: RoundedRectangle(cornerRadius: Theme.radiusField, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusField, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.8))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func dayCell(_ d: Date) -> some View {
        let inMonth = cal.isDate(d, equalTo: visible, toGranularity: .month)
        let isSel = cal.isDate(d, inSameDayAs: selected)
        let isToday = cal.isDateInToday(d)
        return Button { selected = d } label: {
            ZStack {
                if isSel { Circle().fill(Theme.accent) }
                else if isToday { Circle().strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1) }
                Text("\(cal.component(.day, from: d))")
                    .font(Theme.text(12, isSel || isToday ? .semibold : .regular))
                    .foregroundStyle(isSel ? .white : inMonth ? Theme.ink : Theme.ink3)
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var monthTitle: String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f.string(from: visible)
    }
    private var weekdaySymbols: [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(s[first...] + s[..<first])
    }
    /// Six weeks starting from the first weekday on or before the 1st of the visible month.
    private var days: [Date] {
        let comps = cal.dateComponents([.year, .month], from: visible)
        guard let first = cal.date(from: comps) else { return [] }
        let weekday = cal.component(.weekday, from: first)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        guard let gridStart = cal.date(byAdding: .day, value: -lead, to: first) else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }
    private func page(_ by: Int) {
        withAnimation(Theme.springQuick) { visible = cal.date(byAdding: .month, value: by, to: visible) ?? visible }
    }
}

/// Hour chips (12 per period), then minute and AM/PM chips. No scrolling, two clicks for any quarter hour.
struct TimeGrid: View {
    @Binding var selected: Date
    private let cal = Calendar.current

    private var hour24: Int { cal.component(.hour, from: selected) }
    private var minute: Int { cal.component(.minute, from: selected) }
    private var pm: Bool { hour24 >= 12 }
    private var hour12: Int { let h = hour24 % 12; return h == 0 ? 12 : h }

    var body: some View {
        VStack(spacing: 6) {
            let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 6)
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(1...12, id: \.self) { h in
                    cell("\(h)", on: h == hour12) { set(hour12: h, minute: minute, pm: pm) }
                }
            }
            HStack(spacing: 4) {
                ForEach([0, 15, 30, 45], id: \.self) { m in
                    cell(String(format: ":%02d", m), on: m == minute) { set(hour12: hour12, minute: m, pm: pm) }
                }
                Spacer(minLength: 8)
                cell("AM", on: !pm) { set(hour12: hour12, minute: minute, pm: false) }
                cell("PM", on: pm) { set(hour12: hour12, minute: minute, pm: true) }
            }
        }
        .padding(10)
        .background(Theme.fill1, in: RoundedRectangle(cornerRadius: Theme.radiusField, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusField, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.8))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func cell(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(Theme.text(12, on ? .semibold : .regular))
                .frame(maxWidth: .infinity).frame(height: 26)
                .background(on ? Theme.accent : Theme.fill2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(on ? .white : Theme.ink)
        }
        .buttonStyle(.plain)
    }

    private func set(hour12: Int, minute: Int, pm: Bool) {
        let h = (hour12 % 12) + (pm ? 12 : 0)
        if let d = cal.date(bySettingHour: h, minute: minute, second: 0, of: selected) { selected = d }
    }
}

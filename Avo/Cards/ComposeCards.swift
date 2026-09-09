import SwiftUI
import AppKit

/// Bindings into the confirmation's editable values, keyed by tool argument.
struct ConfirmFields {
    @Binding var values: [String: String]
    func bind(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }
    subscript(_ key: String) -> String { values[key] ?? "" }
    func has(_ key: String) -> Bool { !(values[key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
}

// MARK: - Reminder

struct ReminderComposeView: View {
    var card: ConfirmationCard
    var fields: ConfirmFields
    @State private var showNotes = false
    @State private var picking: Picking = .none
    @State private var listColors: [String: String] = [:]
    private enum Picking { case none, date, time }

    private var lists: [String] {
        if case .select(let opts)? = card.fields.first(where: { $0.id == "list" })?.kind { return opts }
        return []
    }
    private var listColor: Color { CardBrand.color(hex: listColors[fields["list"]]) ?? CardBrand.calendar }
    private var due: Date? { fields.has("due") ? ScheduleISO.parse(fields["due"])?.date : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(listColor)
                    Image(systemName: "list.bullet").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    InlineField(placeholder: "Reminder", text: fields.bind("title"), size: 17, weight: .semibold)
                    Text(fields.has("list") ? fields["list"] : "Reminders").font(Theme.text(12.5)).foregroundStyle(Theme.ink3)
                }
            }
            HStack(spacing: 6) {
                ChipButton(text: due.map(ScheduleISO.dayLabel) ?? "Add date", icon: "calendar", active: picking == .date) { toggle(.date) }
                if let d = due {
                    ChipButton(text: ScheduleISO.timeLabel(d), icon: "clock", active: picking == .time) { toggle(.time) }
                    Button { fields.values["due"] = ""; picking = .none } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ink2)
                            .frame(width: 28, height: 28).background(Theme.fill2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }.buttonStyle(.plain).help("Remove due date")
                }
                Spacer(minLength: 4)
                if !lists.isEmpty {
                    Menu {
                        ForEach(lists, id: \.self) { l in
                            Button { fields.values["list"] = l } label: {
                                Label(l, systemImage: fields["list"] == l ? "checkmark" : "circle.fill")
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            ColorDot(color: listColor)
                            Text(fields.has("list") ? fields["list"] : "List").font(Theme.text(12.5, .medium)).foregroundStyle(Theme.ink)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink3)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.fill2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            if picking == .date {
                MonthGrid(selected: Binding(get: { due ?? ScheduleISO.roundedSoon() },
                                            set: { d in setDue(ScheduleISO.combine(day: d, time: due ?? defaultTime(d))); picking = .none }))
            }
            if picking == .time, let d = due {
                TimeGrid(selected: Binding(get: { d }, set: { setDue($0) }))
            }
            if showNotes || fields.has("notes") {
                BodyEditor(text: fields.bind("notes"), minHeight: 44, maxHeight: 120)
            } else {
                Button { withAnimation(Theme.springQuick) { showNotes = true } } label: {
                    Label("Add notes", systemImage: "text.alignleft").font(Theme.text(12, .medium)).foregroundStyle(Theme.ink3)
                }.buttonStyle(.plain)
            }
        }
        .animation(Theme.springQuick, value: picking)
        .task { listColors = await Task.detached { RemindersStore.shared.listColors() }.value }
    }

    private func toggle(_ p: Picking) { picking = picking == p ? .none : p }
    private func defaultTime(_ day: Date) -> Date { Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day }
    private func setDue(_ d: Date) { fields.values["due"] = ScheduleISO.string(d, allDay: false) }
}

// MARK: - Calendar event

struct EventComposeView: View {
    var card: ConfirmationCard
    var fields: ConfirmFields
    var isUpdate: Bool
    @State private var calendars: [GCal.CalendarInfo] = []
    @State private var neighbors: [MiniDayTimeline.Block] = []
    @State private var showGuests = false
    @State private var showSchedule = false

    private var calendarColor: Color {
        let name = fields["calendar"]
        let c = calendars.first { $0.name == name } ?? calendars.first { $0.primary }
        return CardBrand.color(hex: c?.color) ?? CardBrand.calendar
    }
    private var start: Date? { ScheduleISO.parse(fields["start_datetime"])?.date }
    private var end: Date? { ScheduleISO.parse(fields["end_datetime"])?.date }
    private var allDay: Bool { (fields["all_day"] as NSString).boolValue || (ScheduleISO.parse(fields["start_datetime"])?.allDay ?? false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                InlineField(placeholder: "Event title", text: fields.bind("title"), size: 18, weight: .semibold)
                Rectangle().fill(calendarColor).frame(height: 2).clipShape(Capsule())
            }
            if fields.has("start_datetime") || showSchedule || !isUpdate {
                EventScheduleEditor(startISO: fields.bind("start_datetime"), endISO: fields.bind("end_datetime"), allDayISO: fields.bind("all_day"))
            } else {
                HStack(spacing: 8) {
                    Text("Keeps its current time").font(Theme.text(12)).foregroundStyle(Theme.ink2)
                    Spacer()
                    Button("Change time") { withAnimation(Theme.springQuick) { showSchedule = true } }
                        .buttonStyle(.plain).font(Theme.text(12, .semibold)).foregroundStyle(Theme.accent)
                }
            }
            if let s = start, !allDay {
                MiniDayTimeline(start: s, end: end ?? s.addingTimeInterval(3600), neighbors: neighbors, accent: calendarColor,
                                newTitle: fields.has("title") ? fields["title"] : "New event")
                    .padding(.top, 2)
                    .task(id: dayKey(s)) { await loadNeighbors(for: s) }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "mappin.and.ellipse").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink3).frame(width: 16).padding(.top, 2)
                InlineField(placeholder: "Add location", text: fields.bind("location"), size: 13)
            }
            let guestKey = card.fields.contains { $0.id == "attendees" } ? "attendees" : "add_attendees"
            if showGuests || fields.has(guestKey) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "person.2").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink3).frame(width: 16).padding(.top, 5)
                    AddressChips(value: fields.bind(guestKey), placeholder: "Add guests")
                }
            } else {
                Button { withAnimation(Theme.springQuick) { showGuests = true } } label: {
                    Label("Add guests", systemImage: "person.badge.plus").font(Theme.text(12, .medium)).foregroundStyle(Theme.ink3)
                }.buttonStyle(.plain)
            }
        }
        .task {
            if let cals = try? await GCal.calendars() { calendars = cals.filter { $0.writable } }
        }
    }

    /// Header control: calendar picker (create only; update targets a calendar_id already).
    @ViewBuilder var calendarControl: some View {
        if !isUpdate, !calendars.isEmpty {
            Menu {
                ForEach(calendars, id: \.id) { c in
                    Button { fields.values["calendar"] = c.primary ? "" : c.name } label: { Text(c.name) }
                }
            } label: {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(calendarColor).frame(width: 9, height: 9)
                    Text(fields.has("calendar") ? fields["calendar"] : (calendars.first { $0.primary }?.name ?? "Calendar"))
                        .font(Theme.text(12, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.ink3)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.fill1, in: Capsule())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    private func dayKey(_ d: Date) -> String { GoogleDates.ymd(d) }

    private func loadNeighbors(for day: Date) async {
        let cal = Calendar.current
        let from = cal.startOfDay(for: day)
        let to = cal.date(byAdding: .day, value: 1, to: from) ?? day
        let fetch = Task { () -> [MiniDayTimeline.Block] in
            let cals = try await GCal.calendars().filter { $0.selected }
            let events = try await GCal.events(in: cals, from: from, to: to)
            let colors = Dictionary(uniqueKeysWithValues: cals.map { ($0.id, $0.color) })
            return events.filter { !$0.allDay }.map { e in
                MiniDayTimeline.Block(title: e.title, start: e.start.date, end: e.end?.date ?? e.start.date.addingTimeInterval(1800),
                                      color: CardBrand.color(hex: colors[e.calendarId] ?? nil) ?? Theme.ink3)
            }
        }
        let timeout = Task { try? await Task.sleep(nanoseconds: 1_500_000_000); fetch.cancel() }
        if let blocks = try? await fetch.value { neighbors = blocks.filter { !isSameAsNew($0) } }
        timeout.cancel()
    }
    /// When updating, the event itself is already on the calendar; hide that copy.
    private func isSameAsNew(_ b: MiniDayTimeline.Block) -> Bool {
        isUpdate && b.title == fields["title"]
    }
}

// MARK: - Email

struct EmailComposeView: View {
    var card: ConfirmationCard
    var fields: ConfirmFields
    var isReply: Bool
    @State private var showCc = false
    @State private var copiedKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(label: "To") {
                AddressChips(value: fields.bind("to"), placeholder: isReply ? "Original sender" : "Add recipient")
            } trailing: {
                if !isReply, !showCc, !fields.has("cc") {
                    Button("Cc") { withAnimation(Theme.springQuick) { showCc = true } }
                        .buttonStyle(.plain).font(Theme.text(12, .medium)).foregroundStyle(Theme.ink3)
                }
            }
            if !isReply, showCc || fields.has("cc") {
                divider
                row(label: "Cc") { AddressChips(value: fields.bind("cc"), placeholder: "Add cc") } trailing: { EmptyView() }
            }
            if !isReply {
                divider
                row(label: "Subject") {
                    InlineField(placeholder: "Subject", text: fields.bind("subject"), size: 14, weight: .medium)
                } trailing: { copyButton("subject") }
            }
            divider
            HStack(alignment: .top, spacing: 6) {
                TextEditor(text: fields.bind("body"))
                    .font(Theme.text(13.5)).lineSpacing(3).scrollContentBackground(.hidden)
                    .frame(minHeight: 80, maxHeight: 240)
                    .padding(.top, 6)
                copyButton("body").padding(.top, 8)
            }
        }
    }

    private var divider: some View { Divider().overlay(Theme.line).padding(.vertical, 6) }

    private func row<C: View, T: View>(label: String, @ViewBuilder content: () -> C, @ViewBuilder trailing: () -> T) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(Theme.text(13)).foregroundStyle(Theme.ink3).frame(width: 52, alignment: .leading).padding(.top, 4)
            content()
            Spacer(minLength: 4)
            trailing().padding(.top, 4)
        }
    }

    private func copyButton(_ key: String) -> some View {
        Button {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(fields[key], forType: .string)
            withAnimation(Theme.springQuick) { copiedKey = key }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation { if copiedKey == key { copiedKey = nil } } }
        } label: {
            Image(systemName: copiedKey == key ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .medium))
                .foregroundStyle(copiedKey == key ? Theme.good : Theme.ink3).frame(width: 20, height: 20)
        }.buttonStyle(.plain).help("Copy")
    }
}

// MARK: - iMessage

struct MessageComposeView: View {
    var card: ConfirmationCard
    var fields: ConfirmFields
    var onSend: () -> Void
    @State private var context: [(text: String, fromMe: Bool)] = []
    @State private var handle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !context.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(context.enumerated()), id: \.offset) { _, m in
                        HStack {
                            if m.fromMe { Spacer(minLength: 40) }
                            Text(m.text).font(Theme.text(12.5)).foregroundStyle(m.fromMe ? .white : Theme.ink)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(m.fromMe ? Theme.accent.opacity(0.75) : Theme.fill2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .lineLimit(3)
                            if !m.fromMe { Spacer(minLength: 40) }
                        }
                    }
                }
                .opacity(0.8)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: fields.bind("message"))
                    .font(Theme.text(14)).scrollContentBackground(.hidden).lineSpacing(2)
                    .frame(minHeight: 36, maxHeight: 160)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.fill1, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.8))
                Button(action: onSend) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30).background(fields.has("message") ? Color(red: 0.04, green: 0.52, blue: 1.0) : Theme.ink4, in: Circle())
                }
                .buttonStyle(.plain).disabled(!fields.has("message")).keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .task { await loadContext() }
    }

    /// Header: who this goes to.
    var headerName: String { fields.has("to") ? fields["to"] : (fields.has("recipient") ? fields["recipient"] : "New Message") }
    var headerHandle: String { handle }

    private func loadContext() async {
        let guid = fields.has("chat_guid") ? fields["chat_guid"] : nil
        let recipient = fields.has("recipient") ? fields["recipient"] : nil
        guard guid != nil || recipient != nil else { return }
        let fetch = Task.detached { () -> (String, [(String, Bool)])? in
            guard let chat = try? MessagesStore.shared.findChat(guid: guid, recipient: recipient) else { return nil }
            let msgs = (try? MessagesStore.shared.messages(chatId: chat.rowId, limit: 3)) ?? []
            return (chat.identifier, msgs.sorted { $0.date < $1.date }.map { ($0.text, $0.fromMe) }.filter { !$0.0.isEmpty })
        }
        let timeout = Task { try? await Task.sleep(nanoseconds: 300_000_000); fetch.cancel() }
        if let (id, msgs) = await fetch.value {
            handle = id
            context = msgs.map { (text: $0.0, fromMe: $0.1) }
        }
        timeout.cancel()
    }
}

// MARK: - Note

struct NoteComposeView: View {
    var card: ConfirmationCard
    var fields: ConfirmFields
    var isAppend: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isAppend {
                HStack(spacing: 6) {
                    Image(systemName: "note.text").font(.system(size: 11, weight: .semibold)).foregroundStyle(CardBrand.notes)
                    Text(fields.has("note") ? fields["note"] : "Most recent note").font(Theme.text(13, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                }
                BodyEditor(text: fields.bind("text"), minHeight: 70, maxHeight: 220, size: 13.5)
            } else {
                InlineField(placeholder: "Title", text: fields.bind("title"), size: 18, weight: .semibold)
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink3)
                    InlineField(placeholder: "Notes", text: fields.bind("folder"), size: 12, color: Theme.ink2)
                }
                BodyEditor(text: fields.bind("body"), minHeight: 70, maxHeight: 220, size: 13.5)
            }
        }
    }
}

// MARK: - Generic

struct GenericComposeView: View {
    var card: ConfirmationCard
    var fields: ConfirmFields
    var skip: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(card.fields.filter { !skip.contains($0.id) }) { f in
                switch f.kind {
                case .multiline:
                    VStack(alignment: .leading, spacing: 4) {
                        Text(f.label.uppercased()).font(Theme.text(10, .semibold)).foregroundStyle(Theme.ink3).tracking(0.6)
                        BodyEditor(text: fields.bind(f.id), minHeight: 44, maxHeight: 140)
                    }
                case .toggle:
                    LabeledRow(label: f.label) {
                        Toggle(isOn: Binding(get: { (fields[f.id] as NSString).boolValue }, set: { fields.values[f.id] = $0 ? "true" : "false" })) { EmptyView() }
                            .toggleStyle(.switch).controlSize(.small)
                    }
                case .select(let opts):
                    LabeledRow(label: f.label) {
                        Picker("", selection: fields.bind(f.id)) { ForEach(opts, id: \.self) { Text($0).tag($0) } }
                            .labelsHidden().pickerStyle(.menu).controlSize(.small)
                    }
                case .datetime:
                    LabeledRow(label: f.label) { DateTimeField(iso: fields.bind(f.id)) }
                default:
                    LabeledRow(label: f.label) {
                        if ["path", "destination"].contains(f.id), fields.has(f.id) {
                            VStack(alignment: .leading, spacing: 4) {
                                PathChip(path: fields[f.id])
                                TextField("", text: fields.bind(f.id)).textFieldStyle(.plain).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink3)
                            }
                        } else {
                            TextField(f.label, text: fields.bind(f.id))
                                .textFieldStyle(.plain).font(Theme.text(13))
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(Theme.fill1, in: RoundedRectangle(cornerRadius: Theme.radiusField, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Theme.radiusField, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.8))
                        }
                    }
                }
            }
        }
    }
}

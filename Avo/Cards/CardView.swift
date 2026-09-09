import SwiftUI
import AppKit

struct CardView: View {
    let card: AnyCard
    let controller: NotchController
    var body: some View {
        Group {
            switch card.kind {
            case .confirmation(let c): ConfirmationCardView(card: c)
            case .glance(let g): GlanceCardView(card: g)
            case .draft(let d): DraftCardView(card: d)
            case .files(let f): FilesCardView(card: f)
            case .task(let t): TaskCardView(card: t)
            case .reminder(let r): ReminderCardView(card: r)
            case .question(let q): QuestionCardView(card: q)
            }
        }
        .padding(14)
        .background(Theme.fill1, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.8))
    }
}

// MARK: - Shared bits

struct CardHeader: View {
    var icon: String; var title: String; var subtitle: String?
    var body: some View {
        HStack(spacing: 10) {
            ChipIcon(icon: icon, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.text(14, .semibold)).foregroundStyle(Theme.ink)
                if let s = subtitle, !s.isEmpty { Text(s).font(Theme.text(12)).foregroundStyle(Theme.ink2).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
    }
}

struct PillButton: View {
    var label: String; var accent = false; var destructive = false; var shortcut: KeyEquivalent? = nil; var modifiers: EventModifiers = []; var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(Theme.text(13, .semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(accent ? (destructive ? Theme.bad : Theme.accent) : Theme.fill2, in: Capsule())
                .foregroundStyle(accent ? .white : Theme.ink)
        }
        .buttonStyle(.plain)
        .modifier(OptionalShortcut(key: shortcut, modifiers: modifiers))
    }
}
struct OptionalShortcut: ViewModifier {
    var key: KeyEquivalent?
    var modifiers: EventModifiers = []
    func body(content: Content) -> some View {
        if let k = key { content.keyboardShortcut(k, modifiers: modifiers) } else { content }
    }
}

// MARK: - Confirmation

struct ConfirmationCardView: View {
    var card: ConfirmationCard
    @State private var values: [String: String] = [:]
    init(card: ConfirmationCard) { self.card = card; _values = State(initialValue: Dictionary(uniqueKeysWithValues: card.fields.map { ($0.id, $0.value) })) }

    private var fields: ConfirmFields { ConfirmFields(values: $values) }
    private var requiredOK: Bool { card.fields.allSatisfy { !$0.required || !(values[$0.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty } }
    private func confirm() { guard requiredOK else { return }; card.onDecision?(.confirm(values)) }
    private func cancel() { card.onDecision?(.cancel) }
    private var primary: (label: String, destructive: Bool, enabled: Bool, action: () -> Void) {
        (card.confirmLabel, card.destructive, requiredOK, confirm)
    }
    private var tint: Color {
        switch card.layout {
        case .reminder: CardBrand.reminders; case .event: CardBrand.calendar; case .email, .reply: CardBrand.gmail
        case .message: CardBrand.messages; case .note: CardBrand.notes; case .generic: card.destructive ? Theme.bad : Theme.accent
        }
    }

    var body: some View {
        Group {
            switch card.layout {
            case .reminder:
                CardShell(icon: card.icon, tint: tint, title: "New Reminder", onClose: cancel, primary: primary) {
                    ReminderComposeView(card: card, fields: fields)
                }
            case .event:
                let isUpdate = card.title.lowercased().contains("update")
                let compose = EventComposeView(card: card, fields: fields, isUpdate: isUpdate)
                CardShell(icon: card.icon, tint: tint, title: isUpdate ? "Edit Event" : "New Event", onClose: cancel, primary: primary,
                          control: { compose.calendarControl }) { compose }
            case .email:
                CardShell(icon: card.icon, tint: tint, title: "New Message", onClose: cancel, primary: primary) {
                    EmailComposeView(card: card, fields: fields, isReply: false)
                }
            case .reply:
                CardShell(icon: card.icon, tint: tint, title: "Reply", subtitle: card.subtitle, onClose: cancel, primary: primary) {
                    EmailComposeView(card: card, fields: fields, isReply: true)
                }
            case .message:
                let compose = MessageComposeView(card: card, fields: fields, onSend: confirm)
                CardShell(icon: card.icon, tint: tint, title: compose.headerName, subtitle: compose.headerHandle, onClose: cancel, primary: nil) { compose }
            case .note:
                let isAppend = card.title.lowercased().contains("append")
                CardShell(icon: card.icon, tint: tint, title: isAppend ? "Append to Note" : "New Note", onClose: cancel, primary: primary) {
                    NoteComposeView(card: card, fields: fields, isAppend: isAppend)
                }
            case .generic:
                CardShell(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle, onClose: cancel, primary: primary) {
                    GenericComposeView(card: card, fields: fields)
                }
            }
        }
        .onChange(of: card.revision) { _, _ in
            values = Dictionary(uniqueKeysWithValues: card.fields.map { ($0.id, $0.value) })
        }
    }
}

// MARK: - Glance

struct GlanceCardView: View {
    var card: GlanceCard
    private var style: GlanceCard.Style { card.style }
    private var brand: Color { CardBrand.color(for: style) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(card.blocks.enumerated()), id: \.offset) { _, b in block(b) }
            if let s = card.source {
                HStack(spacing: 5) {
                    if let i = card.sourceIcon { AppTile(icon: i, tint: brand, size: 13) }
                    Text(s).font(Theme.text(11, .medium)).foregroundStyle(Theme.ink3)
                }.padding(.top, 2)
            }
        }
    }

    @ViewBuilder private func block(_ b: GlanceCard.Block) -> some View {
        switch b {
        case .header(let t, let s, let i):
            HStack(spacing: 10) {
                AppTile(icon: i, tint: brand, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t).font(Theme.text(14, .semibold)).foregroundStyle(Theme.ink)
                    if let s, !s.isEmpty { Text(s).font(Theme.text(12)).foregroundStyle(Theme.ink2).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
        case .text(let t):
            MarkdownView(source: t, baseFontSize: 13).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        case .list(let rows):
            VStack(spacing: 0) {
                ForEach(rows) { r in
                    SourceRow(row: r, style: style, brand: brand) { open(r) }
                    if r.id != rows.last?.id { Divider().overlay(Theme.line).padding(.leading, rowInset) }
                }
            }
        case .email(let from, let address, let date, let body, let attachments):
            EmailBodyView(from: from, address: address, date: date, body: body, attachments: attachments)
        case .actions(let actions):
            HStack(spacing: 6) {
                ForEach(actions) { a in
                    Button(action: a.run) {
                        HStack(spacing: 5) {
                            if let i = a.icon { Image(systemName: i).font(.system(size: 11, weight: .semibold)) }
                            Text(a.label).font(Theme.text(12.5, .semibold))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(a.accent ? Theme.accent : Theme.fill2, in: Capsule())
                        .foregroundStyle(a.accent ? .white : Theme.ink)
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
        case .stats(let items):
            HStack(spacing: 14) {
                ForEach(items) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.value).font(Theme.font(22, .semibold)).foregroundStyle(Theme.ink)
                        HStack(spacing: 4) {
                            Text(s.label).font(Theme.text(11)).foregroundStyle(Theme.ink3)
                            if let d = s.delta { Text(d).font(Theme.text(11, .semibold)).foregroundStyle(d.hasPrefix("-") ? Theme.bad : Theme.good) }
                        }
                    }
                    if s.id != items.last?.id { Spacer() }
                }
            }
        case .keyValue(let pairs):
            VStack(spacing: 5) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, p in
                    HStack { Text(p.0).font(Theme.text(12)).foregroundStyle(Theme.ink3); Spacer(); Text(p.1).font(Theme.text(12, .medium)).foregroundStyle(Theme.ink).lineLimit(2).multilineTextAlignment(.trailing) }
                }
            }
        case .bars(let items):
            let maxV = items.map { $0.1 }.max() ?? 1
            VStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(spacing: 8) {
                        Text(it.0).font(Theme.text(11)).foregroundStyle(Theme.ink3).frame(width: 64, alignment: .leading).lineLimit(1)
                        GeometryReader { g in
                            Capsule().fill(Theme.fill2).overlay(alignment: .leading) {
                                Capsule().fill(brand).frame(width: g.size.width * CGFloat(maxV > 0 ? it.1 / maxV : 0))
                            }
                        }.frame(height: 8)
                        Text(short(it.1)).font(Theme.text(11, .medium)).foregroundStyle(Theme.ink2).frame(width: 40, alignment: .trailing)
                    }
                }
            }
        case .progress(let v, let m, let label):
            VStack(alignment: .leading, spacing: 4) {
                if let l = label { Text(l).font(Theme.text(12)).foregroundStyle(Theme.ink2) }
                GeometryReader { g in
                    Capsule().fill(Theme.fill2).overlay(alignment: .leading) { Capsule().fill(brand).frame(width: g.size.width * CGFloat(min(1, v / max(m, 0.0001)))) }
                }.frame(height: 6)
            }
        case .badges(let bs):
            HStack(spacing: 6) { ForEach(bs) { b in Text(b.text).font(Theme.text(11, .semibold)).padding(.horizontal, 8).padding(.vertical, 4).background(tone(b.tone).opacity(0.18), in: Capsule()).foregroundStyle(tone(b.tone)) } }
        }
    }
    private var rowInset: CGFloat {
        switch style { case .gmail, .messages: 40; case .calendar: 62; case .reminders: 30; case .files, .spotify: 36; default: 0 }
    }
    private func tone(_ t: GlanceCard.Tone) -> Color { switch t { case .neutral: Theme.ink2; case .good: Theme.good; case .bad: Theme.bad; case .accent: Theme.accent } }
    private func short(_ v: Double) -> String { v >= 1000 ? String(format: "%.1fk", v / 1000) : String(format: v == v.rounded() ? "%.0f" : "%.1f", v) }
    private func open(_ r: GlanceCard.Row) {
        if let p = r.path { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
        else if let u = r.url, let url = URL(string: u) { NSWorkspace.shared.open(url) }
    }
}

/// One list row, shaped by the source app.
struct SourceRow: View {
    var row: GlanceCard.Row
    var style: GlanceCard.Style
    var brand: Color
    var open: () -> Void
    @State private var hover = false
    @State private var checked = false

    private var accent: Color { CardBrand.color(hex: row.accent) ?? brand }
    private func tone(_ t: GlanceCard.Tone) -> Color { switch t { case .neutral: Theme.ink2; case .good: Theme.good; case .bad: Theme.bad; case .accent: Theme.accent } }

    var body: some View {
        Button(action: open) {
            HStack(alignment: style == .calendar ? .top : .center, spacing: 10) {
                leading
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        if row.unread { ColorDot(color: Theme.accent, size: 6) }
                        Text(row.title).font(Theme.text(13, row.unread ? .semibold : .medium)).foregroundStyle(checked ? Theme.ink3 : Theme.ink).lineLimit(1).strikethrough(checked)
                    }
                    if let s = row.subtitle, !s.isEmpty { Text(s).font(Theme.text(12, style == .gmail ? .medium : .regular)).foregroundStyle(style == .gmail ? Theme.ink : Theme.ink2).lineLimit(1) }
                    if let m = row.meta, !m.isEmpty { Text(m).font(Theme.text(11.5)).foregroundStyle(Theme.ink3).lineLimit(style == .gmail ? 2 : 1) }
                }
                Spacer(minLength: 6)
                if let t = row.trailing, style != .calendar { Text(t).font(Theme.text(11.5)).foregroundStyle(tone(row.tone)).lineLimit(1) }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 4)
            .background(hover ? Theme.fill1 : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Theme.springQuick) { hover = h } }
    }

    @ViewBuilder private var leading: some View {
        switch style {
        case .gmail, .messages:
            InitialsAvatar(name: row.avatar ?? row.title, size: 28, tint: style == .gmail ? accent : CardBrand.messages)
        case .calendar:
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(accent).frame(width: 3, height: 30)
                Text(row.trailing ?? "").font(Theme.text(11, .medium)).foregroundStyle(Theme.ink2).frame(width: 54, alignment: .leading).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        case .reminders:
            if row.checkable {
                Button {
                    withAnimation(Theme.springQuick) { checked.toggle() }
                    row.onToggle?()
                } label: {
                    ZStack {
                        Circle().strokeBorder(accent, lineWidth: 1.5)
                        if checked { Circle().fill(accent).padding(3) }
                    }.frame(width: 18, height: 18)
                }.buttonStyle(.plain)
            } else if let i = row.icon {
                Image(systemName: i).font(.system(size: 12, weight: .semibold)).foregroundStyle(accent).frame(width: 18)
            }
        case .files:
            if let p = row.path {
                Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 26, height: 26)
            } else if let i = row.icon { AppTile(icon: i, tint: accent, size: 24) }
        case .spotify:
            if let u = row.imageURL, let url = URL(string: u) {
                AsyncImage(url: url) { img in img.resizable() } placeholder: { RoundedRectangle(cornerRadius: 5).fill(Theme.fill2) }
                    .frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else if let i = row.icon { AppTile(icon: i, tint: accent, size: 24) }
        case .notes:
            Image(systemName: "note.text").font(.system(size: 12, weight: .semibold)).foregroundStyle(CardBrand.notes).frame(width: 18)
        default:
            if let i = row.icon { ChipIcon(icon: i, size: 18) }
        }
    }
}

/// A full email inside a read card.
struct EmailBodyView: View {
    var from: String; var address: String; var date: String; var text: String; var attachments: [String]
    init(from: String, address: String, date: String, body: String, attachments: [String]) {
        self.from = from; self.address = address; self.date = date; self.text = body; self.attachments = attachments
    }
    @State private var expanded = false
    private var visible: String { expanded || text.count <= 1200 ? text : String(text.prefix(1200)) + "…" }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                InitialsAvatar(name: from, size: 30, tint: CardBrand.gmail)
                VStack(alignment: .leading, spacing: 1) {
                    Text(from).font(Theme.text(13, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(address.isEmpty ? date : "\(address) · \(date)").font(Theme.text(11.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if !attachments.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(attachments, id: \.self) { a in
                        HStack(spacing: 5) {
                            Image(systemName: "paperclip").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink3)
                            Text(a).font(Theme.text(11.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4).background(Theme.fill2, in: Capsule())
                    }
                }
            }
            Text(visible).font(Theme.text(13.5)).foregroundStyle(Theme.ink).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if text.count > 1200, !expanded {
                Button("Show more") { withAnimation(Theme.springQuick) { expanded = true } }
                    .buttonStyle(.plain).font(Theme.text(12, .semibold)).foregroundStyle(Theme.accent)
            }
        }
    }
}

// MARK: - Draft (editable, copied)

struct DraftCardView: View {
    var card: DraftCard
    @State private var text: String
    @State private var copied = false
    init(card: DraftCard) { self.card = card; _text = State(initialValue: card.text) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(card.title).font(Theme.text(13, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                PillButton(label: copied ? "Copied" : "Copy") { copy() }
            }
            TextEditor(text: $text)
                .font(Theme.text(13)).scrollContentBackground(.hidden).lineSpacing(2)
                .frame(minHeight: 60, maxHeight: 220)
                .padding(8).background(Theme.fill1, in: RoundedRectangle(cornerRadius: Theme.radiusField, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusField, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.8))
                .onChange(of: text) { _, t in card.onChange?(t) }
                .onChange(of: card.revision) { _, _ in text = card.text }
            Text(card.hint).font(Theme.text(11)).foregroundStyle(Theme.ink3)
        }
    }
    private func copy() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        withAnimation(Theme.springQuick) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { copied = false } }
    }
}

// MARK: - Files

struct FilesCardView: View {
    var card: FilesCard
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.title).font(Theme.text(13, .semibold)).foregroundStyle(Theme.ink)
            ForEach(card.files.prefix(8)) { f in
                HStack(spacing: 10) {
                    Image(nsImage: fileIcon(f.path)).resizable().frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.name).font(Theme.text(13, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(subtitle(f)).font(Theme.text(11)).foregroundStyle(Theme.ink3).lineLimit(1)
                    }
                    Spacer()
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink3)
                    }.buttonStyle(.plain).help("Reveal in Finder")
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: f.path)) } label: {
                        Image(systemName: "arrow.up.forward").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink3)
                    }.buttonStyle(.plain).help("Open")
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: f.path)) }
                .onDrag { NSItemProvider(object: URL(fileURLWithPath: f.path) as NSURL) }
            }
        }
    }
    private func fileIcon(_ p: String) -> NSImage { let i = NSWorkspace.shared.icon(forFile: p); i.size = .init(width: 32, height: 32); return i }
    private func subtitle(_ f: FilesCard.File) -> String {
        var parts: [String] = [(f.path as NSString).deletingLastPathComponent.replacingOccurrences(of: Paths.home.path, with: "~")]
        if let d = f.modified { parts.append(RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Task (coding agent)

struct TaskCardView: View {
    var card: TaskCard
    @State private var reply = ""
    @State private var showLog = false
    private var isClaude: Bool { !card.agent.contains("Codex") }
    private var tint: Color { isClaude ? CardBrand.claude : CardBrand.codex }
    private var active: Bool { card.status == "running" || card.status == "waiting" }
    private var statusWord: String {
        switch card.status { case "running": "Working"; case "waiting": "Needs you"; case "done": "Done"; case "failed": "Failed"; default: card.status.capitalized }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                AppTile(icon: isClaude ? CodingTools.claudeIcon : CodingTools.codexIcon, tint: tint, size: 24)
                Text(card.agent).font(Theme.text(13, .semibold)).foregroundStyle(Theme.ink2)
                Spacer()
                Text(statusWord).font(Theme.text(12.5, .semibold)).foregroundStyle(statusColor)
                if let s = card.startedAt, active {
                    TimelineView(.periodic(from: s, by: 1)) { t in
                        Text(elapsed(t.date.timeIntervalSince(s))).font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit()).foregroundStyle(Theme.ink3)
                    }
                } else if let s = card.startedAt, let f = card.finishedAt {
                    Text(elapsed(f.timeIntervalSince(s))).font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit()).foregroundStyle(Theme.ink3)
                }
            }
            Text(card.title).font(Theme.text(15, .semibold)).foregroundStyle(Theme.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let p = card.project, !p.isEmpty {
                Text("\(active ? "Working in" : "In") \(p)").font(Theme.text(12.5)).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle)
            }
            if card.status == "waiting", let q = card.lines.last, !q.isEmpty {
                Text(q).font(Theme.text(13)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
            if showLog, !card.lines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(card.lines.suffix(12).enumerated()), id: \.offset) { _, l in
                        Text(l).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if active, let l = card.lines.last, !l.isEmpty, card.status != "waiting" {
                Text(l).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink3).lineLimit(1)
            }
            if let r = card.result, card.status != "running" {
                MarkdownView(source: r, baseFontSize: 13).lineLimit(14).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if card.status == "waiting" || card.status == "done" {
                HStack(spacing: 6) {
                    TextField(card.status == "waiting" ? "Answer…" : "Follow up…", text: $reply)
                        .textFieldStyle(.plain).font(Theme.text(13))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Theme.fill1, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.8))
                        .onSubmit { send() }
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 28, height: 28).background(reply.isEmpty ? Theme.ink4 : Theme.accent, in: Circle())
                    }.buttonStyle(.plain).disabled(reply.isEmpty)
                }
            }
            HStack(spacing: 6) {
                ModelChip(agent: card.agentKey, model: card.model, effort: card.effort) { m, e in card.onAction?("model:\(m ?? "")|\(e ?? "")") }
                if !card.lines.isEmpty {
                    Button { withAnimation(Theme.springQuick) { showLog.toggle() } } label: {
                        HStack(spacing: 4) {
                            Text("Details").font(Theme.text(12.5, .medium))
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(showLog ? 180 : 0))
                        }
                        .foregroundStyle(Theme.ink2).padding(.horizontal, 11).padding(.vertical, 7).background(Theme.fill1, in: Capsule())
                    }.buttonStyle(.plain).fixedSize()
                }
                Spacer(minLength: 4)
                Button { card.onAction?("open") } label: {
                    Image(systemName: "folder").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink2)
                        .frame(width: 30, height: 30).background(Theme.fill1, in: Circle())
                }.buttonStyle(.plain).help("Open folder")
                if active { PillButton(label: "Stop", accent: true, destructive: true) { card.onAction?("stop") }.fixedSize() }
            }
        }
    }
    private func send() {
        let t = reply.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }
        card.onAction?("reply:\(t)"); reply = ""
    }
    private func elapsed(_ s: TimeInterval) -> String {
        let n = max(0, Int(s)); return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n % 3600 / 60, n % 60) : String(format: "%d:%02d", n / 60, n % 60)
    }
    private var statusColor: Color { switch card.status { case "done": Theme.good; case "failed": Theme.bad; case "waiting": Theme.warn; default: tint } }
}

/// "Opus 5 · High ▾": pick the model and effort for a coding task. Newest models first; switching a live
/// task relaunches it on the same session so it keeps its context.
struct ModelChip: View {
    var agent: String
    var model: String?
    var effort: String?
    var onChange: (String?, String?) -> Void
    private var label: String {
        let m = ModelCatalog.label(for: model, agent: agent)
        let e = ModelCatalog.effortLabel(effort ?? ModelCatalog.defaultEffort(for: agent))
        return e.isEmpty ? m : "\(m) · \(e)"
    }
    var body: some View {
        Menu {
            Section("Model") {
                ForEach(ModelCatalog.models(for: agent)) { m in
                    Button { onChange(m.id, effort) } label: {
                        if (model ?? ModelCatalog.defaultModel(for: agent).id) == m.id { Label(m.label, systemImage: "checkmark") } else { Text(m.label) }
                    }
                }
            }
            Section("Effort") {
                ForEach(ModelCatalog.efforts(for: agent), id: \.self) { e in
                    Button { onChange(model, e) } label: {
                        if (effort ?? ModelCatalog.defaultEffort(for: agent)) == e { Label(ModelCatalog.effortLabel(e), systemImage: "checkmark") } else { Text(ModelCatalog.effortLabel(e)) }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(label).font(Theme.text(12.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Theme.fill1, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.8))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

// MARK: - Reminder notification

struct ReminderCardView: View {
    var card: ReminderCard
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "bell.fill", title: card.message, subtitle: card.fireAt.formatted(date: .omitted, time: .shortened))
            HStack(spacing: 8) {
                if card.url != nil { PillButton(label: "Open", accent: true) { card.onAction?("open") } }
                PillButton(label: "Done", accent: card.url == nil) { card.onAction?("done") }
                Menu {
                    Button("10 minutes") { card.onAction?("snooze:10") }
                    Button("30 minutes") { card.onAction?("snooze:30") }
                    Button("1 hour") { card.onAction?("snooze:60") }
                    Button("Tomorrow morning") { card.onAction?("snooze:tomorrow") }
                } label: { Text("Snooze").font(Theme.text(13, .semibold)).padding(.horizontal, 12).padding(.vertical, 7).background(Theme.fill2, in: Capsule()) }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
            }
        }
    }
}

// MARK: - Question

struct QuestionCardView: View {
    var card: QuestionCard
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: card.icon, title: card.title, subtitle: nil)
            if !card.body.isEmpty { Text(card.body).font(Theme.text(13)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true).lineLimit(10) }
            if !card.options.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        ForEach(card.options, id: \.self) { o in PillButton(label: o, accent: o == card.options.first) { card.onAnswer?(o) } }
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(card.options, id: \.self) { o in PillButton(label: o, accent: o == card.options.first) { card.onAnswer?(o) } }
                    }
                }
            }
            if card.allowFreeText {
                HStack {
                    TextField("Answer…", text: $text).textFieldStyle(.plain).font(Theme.text(13))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Theme.fill1, in: RoundedRectangle(cornerRadius: Theme.radiusField, style: .continuous))
                        .onSubmit { if !text.isEmpty { card.onAnswer?(text) } }
                    PillButton(label: "Send", accent: true) { if !text.isEmpty { card.onAnswer?(text) } }
                }
            }
        }
    }
}

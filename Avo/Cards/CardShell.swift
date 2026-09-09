import SwiftUI
import AppKit

// MARK: - Brand

/// One accent per app so a card reads as that app without repainting the glass.
enum CardBrand {
    static let gmail = Color(red: 0.92, green: 0.26, blue: 0.21)
    static let calendar = Color(red: 0.26, green: 0.52, blue: 0.96)
    static let reminders = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let notes = Color(red: 1.0, green: 0.80, blue: 0.20)
    static let messages = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let drive = Color(red: 0.98, green: 0.74, blue: 0.02)
    static let finder = Color(red: 0.20, green: 0.60, blue: 1.0)
    static let spotify = Color(red: 0.11, green: 0.73, blue: 0.33)
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let codex = Color(white: 0.9)

    static func color(for style: GlanceCard.Style) -> Color {
        switch style {
        case .gmail: gmail; case .calendar: calendar; case .reminders: reminders; case .notes: notes
        case .messages: messages; case .files: finder; case .spotify: spotify; case .coding: claude; case .plain: Theme.accent
        }
    }
    static func color(hex: String?) -> Color? {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    static func hex(_ c: NSColor?) -> String? {
        guard let c = c?.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

// MARK: - Shell

/// Header (app tile, title, optional control, close) + body + optional footer with one primary action.
struct CardShell<Body: View, Control: View>: View {
    var icon: String
    var tint: Color = Theme.accent
    var title: String
    var subtitle: String? = nil
    var onClose: (() -> Void)? = nil
    var primary: (label: String, destructive: Bool, enabled: Bool, action: () -> Void)? = nil
    @ViewBuilder var control: () -> Control
    @ViewBuilder var content: () -> Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                AppTile(icon: icon, tint: tint, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(Theme.text(13, .semibold)).foregroundStyle(Theme.ink2).lineLimit(1)
                    if let s = subtitle, !s.isEmpty { Text(s).font(Theme.text(11)).foregroundStyle(Theme.ink3).lineLimit(1) }
                }
                control()
                Spacer(minLength: 6)
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ink2)
                            .frame(width: 24, height: 24).background(Theme.fill2, in: Circle())
                    }.buttonStyle(.plain).keyboardShortcut(.escape, modifiers: []).help("Cancel (esc)")
                }
            }
            content()
            if let p = primary {
                HStack {
                    Spacer()
                    // ⌘↩ rather than bare Return: these bodies hold text fields, and a stray Return must not send.
                    PillButton(label: p.label, accent: true, destructive: p.destructive, shortcut: .return, modifiers: [.command], action: p.action)
                        .opacity(p.enabled ? 1 : 0.45)
                        .allowsHitTesting(p.enabled)
                        .help("\(p.label) (⌘↩)")
                }
            }
        }
    }
}

extension CardShell where Control == EmptyView {
    init(icon: String, tint: Color = Theme.accent, title: String, subtitle: String? = nil, onClose: (() -> Void)? = nil,
         primary: (label: String, destructive: Bool, enabled: Bool, action: () -> Void)? = nil, @ViewBuilder content: @escaping () -> Body) {
        self.init(icon: icon, tint: tint, title: title, subtitle: subtitle, onClose: onClose, primary: primary, control: { EmptyView() }, content: content)
    }
}

// MARK: - Primitives

/// App icon when the bundle is installed, otherwise the brand symbol in a tinted rounded square.
struct AppTile: View {
    var icon: String
    var tint: Color = Theme.accent
    var size: CGFloat = 22
    var body: some View {
        if icon.hasPrefix("app:"), let img = AppIcons.icon(bundleId: String(icon.dropFirst(4))) {
            Image(nsImage: img).resizable().frame(width: size, height: size)
        } else if icon.hasPrefix("asset:") {
            Image(String(icon.dropFirst(6))).resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else if icon.hasPrefix("img:"), let img = Thumbnails.image(path: String(icon.dropFirst(4))) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(tint.opacity(0.22))
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 0.6)
                Image(systemName: icon).font(.system(size: size * 0.52, weight: .semibold)).foregroundStyle(tint)
            }
            .frame(width: size, height: size)
        }
    }
}

struct InitialsAvatar: View {
    var name: String
    var size: CGFloat = 30
    var tint: Color = Theme.accent
    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first.map(String.init) }.joined()
        return s.isEmpty ? String(name.prefix(1)) : s
    }
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            Text(initials.uppercased()).font(Theme.font(size * 0.4, .semibold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

struct ColorDot: View {
    var color: Color
    var size: CGFloat = 8
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

/// Small rounded chip that acts like a button; `active` tints it.
struct ChipButton: View {
    var text: String
    var icon: String? = nil
    var active = false
    var tint: Color = Theme.accent
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(active ? tint : Theme.ink3) }
                Text(text).font(Theme.text(12.5, .medium)).foregroundStyle(active ? tint : Theme.ink).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(active ? tint.opacity(0.16) : Theme.fill2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(active ? tint.opacity(0.55) : Theme.line, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }
}

/// Text that reads like app copy until you click into it.
struct InlineField: View {
    var placeholder: String
    @Binding var text: String
    var size: CGFloat = 15
    var weight: Font.Weight = .regular
    var color: Color = Theme.ink
    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Theme.text(size, weight))
            .foregroundStyle(color)
            .lineLimit(1...4)
    }
}

/// Multiline editor with a soft field background; grows to `maxHeight`, then scrolls.
struct BodyEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 60
    var maxHeight: CGFloat = 220
    var size: CGFloat = 13
    var body: some View {
        TextEditor(text: $text)
            .font(Theme.text(size)).lineSpacing(2).scrollContentBackground(.hidden)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .padding(8)
            .background(Theme.fill1, in: RoundedRectangle(cornerRadius: Theme.radiusField, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusField, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.8))
    }
}

/// Comma-separated addresses as chips, each removable, with an inline "add" field.
struct AddressChips: View {
    @Binding var value: String
    var placeholder = "Add"
    @State private var draft = ""
    private var items: [String] { value.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { a in
                HStack(spacing: 4) {
                    Text(displayName(a)).font(Theme.text(12.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Button { remove(a) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.ink3)
                    }.buttonStyle(.plain)
                }
                .padding(.leading, 9).padding(.trailing, 7).padding(.vertical, 5)
                .background(Theme.accent.opacity(0.16), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 0.7))
                .help(a)
            }
            TextField(items.isEmpty ? placeholder : "", text: $draft)
                .textFieldStyle(.plain).font(Theme.text(12.5)).frame(minWidth: 60)
                .onSubmit { commit() }
                .onChange(of: draft) { _, d in if d.hasSuffix(",") || d.hasSuffix(" ") && d.contains("@") { commit() } }
        }
    }
    private func displayName(_ a: String) -> String {
        if let lt = a.firstIndex(of: "<") { return a[..<lt].trimmingCharacters(in: .whitespaces) }
        return a
    }
    private func commit() {
        let d = draft.trimmingCharacters(in: CharacterSet(charactersIn: ", \n"))
        guard !d.isEmpty else { return }
        value = (items + [d]).joined(separator: ", ")
        draft = ""
    }
    private func remove(_ a: String) { value = items.filter { $0 != a }.joined(separator: ", ") }
}

/// Wraps children onto new lines like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

/// A label on the left, content on the right: the generic confirmation row.
struct LabeledRow<Content: View>: View {
    var label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label.uppercased()).font(Theme.text(10, .semibold)).foregroundStyle(Theme.ink3).tracking(0.6)
                .frame(width: 64, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

/// A file path as a folder chip: last two components, full path on hover.
struct PathChip: View {
    var path: String
    var body: some View {
        let parts = (path as NSString).pathComponents.filter { $0 != "/" }
        let short = parts.suffix(2).joined(separator: "/")
        HStack(spacing: 5) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 16, height: 16)
            Text(short.isEmpty ? path : short).font(Theme.text(12.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Theme.fill2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(path)
    }
}

// MARK: - Day timeline

/// A slice of one day around an event, Google-Calendar style: hour rules, neighbor blocks, the new event in accent.
struct MiniDayTimeline: View {
    struct Block: Identifiable { let id = UUID(); var title: String; var start: Date; var end: Date; var color: Color; var isNew = false }
    var start: Date
    var end: Date
    var neighbors: [Block]
    var accent: Color = CardBrand.calendar
    var newTitle: String = "New event"
    private let hourHeight: CGFloat = 34

    private var window: (Date, Date) {
        let cal = Calendar.current
        let s = cal.date(bySetting: .minute, value: 0, of: cal.date(byAdding: .hour, value: -1, to: start) ?? start) ?? start
        let e = cal.date(byAdding: .hour, value: 1, to: cal.date(bySetting: .minute, value: 0, of: end) ?? end) ?? end
        let minEnd = cal.date(byAdding: .hour, value: 3, to: s) ?? e
        return (s, max(e, minEnd))
    }

    var body: some View {
        let (ws, we) = window
        let hours = max(1, Int(we.timeIntervalSince(ws) / 3600))
        let all = neighbors + [Block(title: newTitle, start: start, end: end, color: accent, isNew: true)]
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<hours, id: \.self) { i in
                    HStack(alignment: .top, spacing: 6) {
                        Text(hourLabel(ws.addingTimeInterval(Double(i) * 3600))).font(Theme.text(9.5)).foregroundStyle(Theme.ink3)
                            .frame(width: 26, alignment: .trailing).offset(y: -6)
                        Rectangle().fill(Theme.line).frame(height: 0.8)
                    }
                    .frame(height: hourHeight, alignment: .top)
                }
            }
            GeometryReader { g in
                let lanes = laneAssign(all)
                let laneWidth = (g.size.width - 34) / CGFloat(max(1, lanes.count))
                ForEach(Array(all.enumerated()), id: \.element.id) { i, b in
                    let y = CGFloat(b.start.timeIntervalSince(ws) / 3600) * hourHeight
                    let h = max(14, CGFloat(b.end.timeIntervalSince(b.start) / 3600) * hourHeight - 2)
                    let lane = lanes.firstIndex { $0.contains(i) } ?? 0
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(b.isNew ? b.color : b.color.opacity(0.28))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(b.color.opacity(b.isNew ? 0 : 0.5), lineWidth: 0.7))
                        .overlay(alignment: .topLeading) {
                            Text(b.isNew ? (b.title) : b.title).font(Theme.text(10, b.isNew ? .semibold : .medium))
                                .foregroundStyle(b.isNew ? .white : Theme.ink).lineLimit(2).padding(.horizontal, 5).padding(.top, 3)
                        }
                        .frame(width: max(20, laneWidth - 3), height: h)
                        .offset(x: 34 + CGFloat(lane) * laneWidth, y: y)
                }
            }
        }
        .frame(height: CGFloat(hours) * hourHeight + 4)
        .clipped()
    }

    private func hourLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "ha"; return f.string(from: d).lowercased()
    }
    /// Greedy lanes: overlapping blocks go side by side.
    private func laneAssign(_ blocks: [Block]) -> [[Int]] {
        var lanes: [[Int]] = []
        for (i, b) in blocks.enumerated() {
            if let li = lanes.firstIndex(where: { lane in !lane.contains { j in blocks[j].start < b.end && b.start < blocks[j].end } }) {
                lanes[li].append(i)
            } else { lanes.append([i]) }
        }
        return lanes
    }
}

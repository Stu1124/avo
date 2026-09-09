import AppKit
import SwiftUI
import AVFoundation
import CoreLocation
import EventKit
import Speech

/// Shared controls for Avo's windows (Settings, Onboarding, History).
/// Dark glass only, SF Pro, radii 14 (controls) / 18 (cards). No light mode.
enum DS {
    static let radiusCard: CGFloat = 18
    static let radiusControl: CGFloat = 14
    static let sidebarWidth: CGFloat = 184
    static let pagePadding: CGFloat = 28

    /// Spacing scale. Every margin and gap in these windows is one of these; nothing in between.
    enum Space {
        /// 4 — inside a label stack.
        static let xs: CGFloat = 4
        /// 8 — between a control and its neighbour.
        static let s: CGFloat = 8
        /// 12 — row padding, vertical rhythm inside a card.
        static let m: CGFloat = 12
        /// 16 — row padding, horizontal gutter inside a card.
        static let l: CGFloat = 16
        /// 24 — between cards on a page.
        static let xl: CGFloat = 24
    }

    /// Type scale. Sizes are whole points and each one has a job; half-point sizes drifted in
    /// because a row "looked slightly big", which is how eight near-identical sizes happen.
    enum Size {
        /// 11 — uppercase section labels only. Never a sentence.
        static let label: CGFloat = 11
        /// 12 — supporting lines: row subtitles, card footers, pill and menu labels.
        static let caption: CGFloat = 12
        /// 13 — the default. Row titles, list text, field contents.
        static let body: CGFloat = 13
        /// 15 — a line that has to carry a step on its own.
        static let lead: CGFloat = 15
        /// 22 — page and window titles.
        static let title: CGFloat = 22
        /// 28 — onboarding step headline.
        static let display: CGFloat = 28
        /// 34 — the one line at the top of an onboarding step. Takes tracking of −1.2.
        static let hero: CGFloat = 34
    }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func mono(_ size: CGFloat = 11, _ weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight, design: .monospaced) }

    /// Fill for a filled control: a slight vertical lift on the accent, so the pill reads as lit
    /// from above rather than as a flat swatch. Paired with `innerHighlight`.
    static let accentFill = LinearGradient(colors: [Color(red: 0.38, green: 0.66, blue: 1.0), Theme.accent],
                                           startPoint: .top, endPoint: .bottom)
    /// The 1 px bevel that goes on top of `accentFill`: bright at the crown, gone by the base.
    static let innerHighlight = LinearGradient(colors: [Color.white.opacity(0.40), Color.white.opacity(0.05)],
                                               startPoint: .top, endPoint: .bottom)
}

// MARK: - Window

/// Builds a dark, title-less window with an NSVisualEffectView (hudWindow) behind SwiftUI content.
@MainActor
enum DarkWindow {
    static func make<Content: View>(title: String, size: NSSize, resizable: Bool = false, minSize: NSSize? = nil, content: Content) -> NSWindow {
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { mask.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: mask, backing: .buffered, defer: false)
        w.title = title
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = true
        if let minSize { w.minSize = minSize }
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // A window built in code (not loaded from a nib) leaves this off, so its key-view loop is
        // never recalculated and Tab reaches nothing inside the hosting view.
        w.autorecalculatesKeyViewLoop = true

        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .darkAqua)
        fx.autoresizingMask = [.width, .height]

        let host = NSHostingView(rootView: WindowChrome { content })
        host.frame = fx.bounds
        host.autoresizingMask = [.width, .height]
        fx.addSubview(host)
        w.contentView = fx
        w.center()
        return w
    }

    static func present(_ w: NSWindow) {
        activate()
        if !w.isVisible { w.center() }
        w.makeKeyAndOrderFront(nil)
        // Avo runs as an accessory app, so nothing makes it frontmost on its own. Until it is active
        // no window of its own is key, and a window that is not key has no field editor: text fields
        // show no caret and swallow typing. One activation can lose the race with whatever was in
        // front, so ask again on the next pass and take the window key with it.
        DispatchQueue.main.async {
            guard !w.isKeyWindow else { return }
            activate()
            w.makeKeyAndOrderFront(nil)
        }
    }

    /// `activate(ignoringOtherApps:)` is deprecated and unreliable for accessory apps. The
    /// deployment floor is macOS 15, so the modern call needs no availability check.
    private static func activate() { NSApp.activate() }
}

/// Glass tint layered over the window's visual effect view.
struct WindowChrome<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            Theme.glass.opacity(0.86)
            LinearGradient(colors: [Color.white.opacity(0.04), .clear, Color.black.opacity(0.18)],
                           startPoint: .top, endPoint: .bottom)
            content
        }
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }
}

// MARK: - Sidebar

struct SidebarItem: Identifiable, Hashable {
    let id: String
    let label: String
    let icon: String
}

struct Sidebar<Header: View>: View {
    var items: [SidebarItem]
    @Binding var selection: String
    @ViewBuilder var header: Header

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
                .padding(.top, 48)
                .padding(.bottom, DS.Space.l)
                .padding(.horizontal, 10)
            ForEach(items) { item in
                let on = selection == item.id
                Button {
                    withAnimation(Theme.springQuick) { selection = item.id }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 20)
                            .foregroundStyle(on ? Theme.accent : Theme.ink3)
                        Text(item.label)
                            .font(DS.font(DS.Size.body, on ? .semibold : .medium))
                            .foregroundStyle(on ? Theme.ink : Theme.ink2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, DS.Space.s)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(on ? Theme.fill2 : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(width: DS.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.24))
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }
}

// MARK: - Page scaffolding

struct PageHeader: View {
    var title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(DS.font(DS.Size.title, .semibold)).foregroundStyle(Theme.ink).tracking(-0.4)
            if let subtitle {
                Text(subtitle).font(DS.font(DS.Size.body)).foregroundStyle(Theme.ink2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }
}

@resultBuilder
enum RowBuilder {
    static func buildBlock(_ parts: [AnyView]...) -> [AnyView] { parts.flatMap { $0 } }
    static func buildExpression<V: View>(_ v: V) -> [AnyView] { [AnyView(v)] }
    static func buildExpression(_ v: [AnyView]) -> [AnyView] { v }
    static func buildOptional(_ p: [AnyView]?) -> [AnyView] { p ?? [] }
    static func buildEither(first: [AnyView]) -> [AnyView] { first }
    static func buildEither(second: [AnyView]) -> [AnyView] { second }
    static func buildArray(_ parts: [[AnyView]]) -> [AnyView] { parts.flatMap { $0 } }
}

/// A rounded card containing rows separated by hairlines.
struct SectionCard: View {
    var title: String? = nil
    var footer: String? = nil
    var rows: [AnyView]

    init(title: String? = nil, footer: String? = nil, @RowBuilder rows: () -> [AnyView]) {
        self.title = title; self.footer = footer; self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let title {
                Text(title.uppercased()).font(DS.font(DS.Size.label, .semibold)).tracking(0.7)
                    .foregroundStyle(Theme.ink3).padding(.leading, DS.Space.xs)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, DS.Space.l) }
                    row
                }
            }
            .cardChrome()
            if let footer {
                Text(footer).font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3).padding(.leading, DS.Space.xs)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension View {
    /// The one card surface: `Theme.fill1` behind a continuous `DS.radiusCard` rectangle with a
    /// hairline border. `SectionCard` and every hand-built panel go through this so the two cannot
    /// drift apart.
    func cardChrome() -> some View {
        background(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).fill(Theme.fill1))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.8))
    }
}

/// Leading label block used by every row.
struct RowLabel: View {
    var title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var body: some View {
        HStack(spacing: DS.Space.m) {
            if let icon { GroupIcon(icon: icon, size: 22) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.font(DS.Size.body, .medium)).foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle).font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Generic row: label on the left, arbitrary trailing content on the right.
struct ActionRow<Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    var icon: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: DS.Space.m) {
            RowLabel(title: title, subtitle: subtitle, icon: icon)
            Spacer(minLength: DS.Space.m)
            trailing
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }
}

struct ToggleRow: View {
    var title: String
    var subtitle: String? = nil
    var icon: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        ActionRow(title: title, subtitle: subtitle, icon: icon) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(DSToggleStyle())
        }
    }
}

struct PickerRow: View {
    var title: String
    var subtitle: String? = nil
    @Binding var selection: String
    var options: [(id: String, label: String)]
    init(title: String, subtitle: String? = nil, selection: Binding<String>, options: [String]) {
        self.title = title; self.subtitle = subtitle; self._selection = selection
        self.options = options.map { (id: $0, label: $0) }
    }
    init(title: String, subtitle: String? = nil, selection: Binding<String>, options: [(id: String, label: String)]) {
        self.title = title; self.subtitle = subtitle; self._selection = selection; self.options = options
    }
    var body: some View {
        ActionRow(title: title, subtitle: subtitle) {
            DSMenu(selection: $selection, options: options)
        }
    }
}

struct TextRow: View {
    var title: String
    var subtitle: String? = nil
    var placeholder: String = ""
    @Binding var text: String
    var width: CGFloat = 200
    var focused: FocusState<Bool>.Binding? = nil
    var body: some View {
        ActionRow(title: title, subtitle: subtitle) {
            DSTextField(placeholder: placeholder, text: $text, focused: focused).frame(width: width)
        }
    }
}

extension View {
    /// `.focused(_:)` with an optional binding, so one shared control can take a focus binding or not.
    @ViewBuilder func focusedIf(_ binding: FocusState<Bool>.Binding?) -> some View {
        if let binding { self.focused(binding) } else { self }
    }
}

// MARK: - Controls

struct DSToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(Theme.springQuick) { configuration.isOn.toggle() }
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Theme.accent : Theme.fill2)
                    .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.8))
                Circle().fill(Color.white)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .padding(2)
            }
            .frame(width: 38, height: 22)
        }
        .buttonStyle(.plain)
    }
}

/// Dropdown styled as a small dark pill.
struct DSMenu: View {
    @Binding var selection: String
    var options: [(id: String, label: String)]
    var body: some View {
        Menu {
            ForEach(options, id: \.id) { o in
                Button {
                    selection = o.id
                } label: {
                    if o.id == selection { Label(o.label, systemImage: "checkmark") } else { Text(o.label) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.id == selection }?.label ?? selection)
                    .font(DS.font(DS.Size.caption, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, 6)
            .background(Capsule().fill(Theme.fill2))
            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.8))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct DSTextField: View {
    var placeholder: String = ""
    @Binding var text: String
    var mono = false
    /// Set to give the field the caret on appear, or to move focus into it programmatically.
    var focused: FocusState<Bool>.Binding? = nil
    var body: some View {
        TextField(placeholder, text: $text)
            .focusedIf(focused)
            .textFieldStyle(.plain)
            .font(mono ? DS.mono(DS.Size.caption, .regular) : DS.font(DS.Size.body))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
            .background(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous).fill(Color.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.8))
    }
}

/// `DSTextField` for values that run to several lines.
struct DSTextEditor: View {
    @Binding var text: String
    var height: CGFloat = 104
    var body: some View {
        TextEditor(text: $text)
            .textEditorStyle(.plain)
            .scrollContentBackground(.hidden)
            .font(DS.font(DS.Size.body))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, DS.Space.s).padding(.vertical, 6)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous).fill(Color.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.8))
    }
}

/// Row whose editor sits under the label rather than beside it, for text too long for one line.
struct MultilineTextRow: View {
    var title: String
    var subtitle: String? = nil
    @Binding var text: String
    var height: CGFloat = 104
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            RowLabel(title: title, subtitle: subtitle)
            DSTextEditor(text: $text, height: height)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }
}

enum PillStyle { case primary, secondary, destructive, ghost }

struct DSPill: View {
    var label: String
    var icon: String? = nil
    var style: PillStyle = .secondary
    var busy = false
    var action: () -> Void

    init(_ label: String, icon: String? = nil, style: PillStyle = .secondary, busy: Bool = false, action: @escaping () -> Void) {
        self.label = label; self.icon = icon; self.style = style; self.busy = busy; self.action = action
    }

    private var fill: Color {
        switch style {
        case .primary: return Theme.accent
        case .secondary: return Theme.fill2
        case .destructive: return Theme.bad.opacity(0.18)
        case .ghost: return .clear
        }
    }
    private var fg: Color {
        switch style {
        case .primary: return .white
        case .secondary: return Theme.ink
        case .destructive: return Theme.bad
        case .ghost: return Theme.ink2
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.mini).tint(fg).frame(width: 12, height: 12)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                }
                Text(label).font(DS.font(DS.Size.caption, .semibold)).lineLimit(1)
            }
            .foregroundStyle(fg)
            .padding(.horizontal, DS.Space.m).padding(.vertical, 6)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(style == .primary ? Color.white.opacity(0.18) : Theme.line, lineWidth: 0.8))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.75 : 1)
    }
}

/// Larger call-to-action for onboarding. The primary style is a gradient pill with a 1 px inner
/// highlight; the ghost style is the same shape with nothing in it. Both take their press state on
/// pointer-down, so the feedback lands with the click rather than with the action.
struct BigButton: View {
    var label: String
    var style: PillStyle = .primary
    var busy = false
    var action: () -> Void
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var primary: Bool { style == .primary }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small).tint(primary ? .white : Theme.ink) }
                Text(label).font(DS.font(DS.Size.lead, .semibold))
            }
            .foregroundStyle(primary ? .white : Theme.ink2)
            .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.m)
            .background {
                if primary {
                    Capsule().fill(DS.accentFill)
                } else {
                    Capsule().fill(Color.white.opacity(pressed ? 0.07 : 0.02))
                }
            }
            .overlay(Capsule().strokeBorder(primary ? AnyShapeStyle(DS.innerHighlight) : AnyShapeStyle(Theme.line),
                                            lineWidth: primary ? 1 : 0.8))
            .shadow(color: primary ? Theme.accent.opacity(pressed ? 0.22 : 0.38) : .clear, radius: 16, y: 6)
            .contentShape(Capsule())
            .scaleEffect(pressed && !reduceMotion ? 0.975 : 1)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onLongPressGesture(minimumDuration: 0, pressing: { p in
            withAnimation(reduceMotion ? nil : Theme.springQuick) { pressed = p }
        }, perform: {})
    }
}

/// Thin segmented progress across the top of a stepped flow. Segments already passed stay lit at
/// half strength, so the bar reads as distance covered rather than as six identical dots.
struct SegmentedProgress: View {
    var count: Int
    var index: Int
    var height: CGFloat = 3

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? AnyShapeStyle(DS.accentFill)
                          : AnyShapeStyle(i < index ? Theme.accent.opacity(0.42) : Color.white.opacity(0.09)))
                    .frame(height: height)
            }
        }
        .animation(Theme.springCard, value: index)
    }
}

/// Centred icon + line for a list with nothing in it. Says what would be here, not "empty".
struct EmptyState: View {
    var icon: String
    var text: String
    var topPadding: CGFloat = 48
    var body: some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: icon).font(.system(size: 26, weight: .medium)).foregroundStyle(Theme.ink4)
            Text(text).font(DS.font(DS.Size.body)).foregroundStyle(Theme.ink3).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, topPadding)
    }
}

enum DotState { case ok, warn, bad, off }

struct StatusDot: View {
    var state: DotState
    var body: some View {
        let c: Color = {
            switch state { case .ok: return Theme.good; case .warn: return Theme.warn; case .bad: return Theme.bad; case .off: return Theme.ink4 }
        }()
        Circle().fill(c).frame(width: 8, height: 8)
            .shadow(color: state == .off ? .clear : c.opacity(0.6), radius: 4)
    }
}

struct StatusLabel: View {
    var state: DotState
    var text: String
    var body: some View {
        HStack(spacing: 6) {
            StatusDot(state: state)
            Text(text).font(DS.font(DS.Size.caption, .medium)).foregroundStyle(Theme.ink2)
        }
    }
}

/// App icon for "app:<bundle id>" or an SF symbol, in a small rounded tile.
struct GroupIcon: View {
    var icon: String
    var size: CGFloat = 24
    var body: some View {
        Group {
            if icon.hasPrefix("app:"), let img = AppIcons.icon(bundleId: String(icon.dropFirst(4))) {
                Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
            } else {
                Image(systemName: icon.hasPrefix("app:") ? "app.fill" : icon)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Theme.fill2))
            }
        }
    }
}

/// Keyboard keycap glyph for hotkey displays.
struct KeyCap: View {
    var text: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
            Text(text).font(DS.font(DS.Size.caption, .semibold))
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.fill2))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.lineStrong, lineWidth: 0.8))
        .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
    }
}

// MARK: - Secret key field

enum KeyProvider: String, CaseIterable, Identifiable {
    case openAI, gemini, fish, xai
    var id: String { rawValue }
    var title: String {
        switch self { case .openAI: return "API key"; case .gemini: return "Gemini"; case .fish: return "Fish Audio"; case .xai: return "xAI" }
    }
    var subtitle: String {
        switch self {
        case .openAI: return "Brain model. Voice mode needs OpenAI."
        case .gemini: return "Spoken replies (TTS)"
        case .fish: return "Alternate voices"
        case .xai: return "Grok, optional"
        }
    }
    var keychainKey: String {
        switch self { case .openAI: return "openai"; case .gemini: return "gemini"; case .fish: return "fish"; case .xai: return "xai" }
    }
    var placeholder: String {
        switch self { case .openAI: return "sk-…"; case .gemini: return "AIza…"; case .fish: return "Fish Audio API key"; case .xai: return "xai-…" }
    }
    func read() -> String { Keychain.get(keychainKey) ?? "" }
    func write(_ v: String) {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { Keychain.delete(keychainKey) } else { Keychain.set(keychainKey, t) }
    }

    /// Cheap authenticated GET to validate the key.
    func test(_ key: String) async -> (ok: Bool, message: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return (false, "No key") }
        var req: URLRequest
        switch self {
        case .openAI:
            // Whatever base URL the brain is pointed at, not a hardcoded OpenAI host.
            let base = await MainActor.run { Settings.shared.apiBaseURL }
            req = URLRequest(url: ProviderURL.endpoint("models", base: base))
            req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        case .gemini:
            var comps = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            comps.queryItems = [.init(name: "key", value: k)]
            req = URLRequest(url: comps.url!)
        case .fish:
            req = URLRequest(url: URL(string: "https://api.fish.audio/wallet/self/api-credit")!)
            req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        case .xai:
            req = URLRequest(url: URL(string: "https://api.x.ai/v1/models")!)
            req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let n = (obj["data"] as? [Any])?.count ?? (obj["models"] as? [Any])?.count
                    if let n { return (true, "Valid · \(n) models") }
                }
                return (true, "Valid")
            }
            switch status {
            case 401, 403: return (false, "Rejected (\(status))")
            case 429: return (false, "Rate limited (429)")
            default: return (false, "HTTP \(status)")
            }
        } catch {
            return (false, "Network error")
        }
    }
}

/// Secure field with show/hide and a Test button. Writes to the Keychain on every change.
struct KeyField: View {
    let provider: KeyProvider
    /// Called with the outcome of every Test, and with nil when the key is edited afterwards. Lets a
    /// view outside the row — the onboarding stage — show the same result without duplicating the call.
    var onResult: ((Bool?) -> Void)? = nil
    @State private var value: String
    @State private var reveal = false
    @State private var testing = false
    @State private var result: (ok: Bool, message: String)? = nil

    init(provider: KeyProvider, onResult: ((Bool?) -> Void)? = nil) {
        self.provider = provider
        self.onResult = onResult
        _value = State(initialValue: provider.read())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.m) {
                RowLabel(title: provider.title, subtitle: provider.subtitle)
                Spacer(minLength: DS.Space.m)
                if let result {
                    StatusLabel(state: result.ok ? .ok : .bad, text: result.message)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                DSPill("Test", busy: testing) {
                    testing = true
                    let p = provider, v = value
                    Task {
                        let r = await p.test(v)
                        withAnimation(Theme.springQuick) { result = r; testing = false }
                        onResult?(r.ok)
                    }
                }
                .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(value.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
            HStack(spacing: 8) {
                Group {
                    if reveal {
                        TextField(provider.placeholder, text: $value)
                    } else {
                        SecureField(provider.placeholder, text: $value)
                    }
                }
                .textFieldStyle(.plain)
                .font(DS.mono(12, .regular))
                .foregroundStyle(Theme.ink)
                Button {
                    reveal.toggle()
                } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink3)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(reveal ? "Hide" : "Show")
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
            .background(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous).fill(Color.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.8))
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .onChange(of: value) { _, v in
            provider.write(v)
            result = nil
            onResult?(nil)
        }
    }
}

// MARK: - Permissions

enum PermissionStatus { case granted, notDetermined, denied, unknown }

enum PermissionKind: String, CaseIterable, Identifiable {
    case inputMonitoring, accessibility, screenRecording, microphone, speechRecognition, fullDiskAccess, reminders, calendars, location, automation
    var id: String { rawValue }

    var title: String {
        switch self {
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .fullDiskAccess: return "Full Disk Access"
        case .reminders: return "Reminders"
        case .calendars: return "Calendars"
        case .location: return "Location"
        case .automation: return "Automation"
        }
    }
    var detail: String {
        switch self {
        case .inputMonitoring: return "Detects the talk key in any app."
        case .accessibility: return "Reads selected text and the front app."
        case .screenRecording: return "Lets Avo see your screen on request."
        case .microphone: return "Hears you while you hold your talk key."
        case .speechRecognition: return "Turns speech into text on this Mac."
        case .fullDiskAccess: return "Reads iMessage history for context."
        case .reminders: return "Creates and reads your reminders."
        case .calendars: return "Reads events from Apple Calendar."
        case .location: return "Where you are, for nearby searches."
        case .automation: return "Controls Messages, Spotify and more."
        }
    }
    var icon: String {
        switch self {
        case .inputMonitoring: return "keyboard"
        case .accessibility: return "figure.wave"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .microphone: return "mic.fill"
        case .speechRecognition: return "waveform.badge.mic"
        case .fullDiskAccess: return "internaldrive.fill"
        case .reminders: return "checklist"
        case .calendars: return "calendar"
        case .location: return "location.fill"
        case .automation: return "gearshape.2.fill"
        }
    }
    var pane: String {
        switch self {
        case .inputMonitoring: return "Privacy_ListenEvent"
        case .accessibility: return "Privacy_Accessibility"
        case .screenRecording: return "Privacy_ScreenCapture"
        case .microphone: return "Privacy_Microphone"
        case .speechRecognition: return "Privacy_SpeechRecognition"
        case .fullDiskAccess: return "Privacy_AllFiles"
        case .reminders: return "Privacy_Reminders"
        case .calendars: return "Privacy_Calendars"
        case .location: return "Privacy_LocationServices"
        case .automation: return "Privacy_Automation"
        }
    }
    /// Whether an in-app request API exists.
    var canRequest: Bool { self != .fullDiskAccess }
    /// Required for the core hold-to-talk flow.
    var essential: Bool { Self.upFront.contains(self) }
    /// The four onboarding asks, in the order both onboarding and Settings show them: the two the
    /// loop cannot work without come first, then the two that can be granted later.
    static let upFront: [PermissionKind] = [.microphone, .speechRecognition, .inputMonitoring, .accessibility]

    func status() -> PermissionStatus {
        switch self {
        case .inputMonitoring: return Permissions.inputMonitoring ? .granted : .denied
        case .accessibility: return Permissions.accessibility ? .granted : .denied
        case .screenRecording: return Permissions.screen ? .granted : .denied
        case .fullDiskAccess: return Permissions.fullDiskAccess ? .granted : .denied
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .reminders:
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .fullAccess, .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .calendars:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess, .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .location:
            switch LocationPrompt.status {
            case .authorizedAlways, .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .automation:
            return Self.automationStatus(ask: false)
        }
    }

    /// Automation is per target app; Finder is always running, so it stands in for the pane.
    private static func automationStatus(ask: Bool) -> PermissionStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let desc = target.aeDesc else { return .unknown }
        let wild = AEEventClass(truncatingIfNeeded: typeWildCard)
        let err = AEDeterminePermissionToAutomateTarget(desc, wild, AEEventID(wild), ask)
        switch err {
        case 0: return .granted
        case -1743: return .denied
        case -1744: return .notDetermined
        default: return .unknown
        }
    }

    /// Triggers the system prompt where one exists; otherwise opens the pane.
    func request() {
        switch self {
        case .inputMonitoring: Permissions.requestInputMonitoring()
        case .accessibility: Permissions.requestAccessibility()
        case .screenRecording: Permissions.requestScreen()
        case .fullDiskAccess: Permissions.open(pane)
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else { Permissions.open(pane) }
        case .speechRecognition:
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                SFSpeechRecognizer.requestAuthorization { _ in }
            } else { Permissions.open(pane) }
        case .reminders:
            if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
                let store = EKEventStore()
                Task { _ = try? await store.requestFullAccessToReminders() }
            } else { Permissions.open(pane) }
        case .calendars:
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                let store = EKEventStore()
                Task { _ = try? await store.requestFullAccessToEvents() }
            } else { Permissions.open(pane) }
        case .location:
            if LocationPrompt.status == .notDetermined {
                LocationPrompt.request()
            } else { Permissions.open(pane) }
        case .automation:
            let current = Self.automationStatus(ask: false)
            if current == .notDetermined || current == .unknown {
                Task.detached { _ = Self.automationStatus(ask: true) }
            } else { Permissions.open(pane) }
        }
    }
}

/// Polls permission status while a view that needs live values is on screen.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var status: [PermissionKind: PermissionStatus] = [:]
    private var timer: Timer?

    init() { refresh() }

    func refresh() {
        var s: [PermissionKind: PermissionStatus] = [:]
        for k in PermissionKind.allCases { s[k] = k.status() }
        guard s != status else { return }
        // Launch skips the audio warm-up while the microphone prompt is unanswered, because touching
        // the input graph then blocks the main actor. This poll is the first thing that sees the
        // grant, from either the onboarding permissions step or Settings → Permissions.
        let granted = status[.microphone] != .granted && s[.microphone] == .granted
        status = s
        if granted { Transcriber.shared.permissionDidChange() }
    }

    func start(interval: TimeInterval) {
        stop()
        refresh()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    func dot(_ k: PermissionKind) -> DotState {
        switch status[k] ?? .unknown {
        case .granted: return .ok
        case .notDetermined: return .warn
        case .denied: return .bad
        case .unknown: return .off
        }
    }
    func label(_ k: PermissionKind) -> String {
        switch status[k] ?? .unknown {
        case .granted: return "Granted"
        case .notDetermined: return "Not asked"
        case .denied: return "Not granted"
        case .unknown: return "Unknown"
        }
    }
    var allEssentialGranted: Bool { PermissionKind.allCases.filter(\.essential).allSatisfy { status[$0] == .granted } }
}

/// One permission row, shared by Settings and Onboarding.
struct PermissionRow: View {
    let kind: PermissionKind
    @ObservedObject var model: PermissionsModel
    /// Status and Request each keep their column whether or not this row uses it, so the eight rows
    /// read as three aligned columns instead of a ragged right edge.
    private static let statusWidth: CGFloat = 104
    private static let requestWidth: CGFloat = 82

    var body: some View {
        let st = model.status[kind] ?? .unknown
        ActionRow(title: kind.title, subtitle: kind.detail, icon: kind.icon) {
            StatusLabel(state: model.dot(kind), text: model.label(kind))
                .frame(width: Self.statusWidth, alignment: .leading)
            Group {
                if st != .granted, kind.canRequest {
                    DSPill("Request", style: .primary) { kind.request() }
                }
            }
            .frame(width: Self.requestWidth)
            DSPill("Open Settings", icon: "arrow.up.forward") { Permissions.open(kind.pane) }
        }
    }
}

// MARK: - Voice preview

/// Synthesizes a short line with the current TTS settings and plays it.
@MainActor
final class VoicePreview: ObservableObject {
    static let shared = VoicePreview()
    static let line = "Good evening. Avo is ready."
    private let player = AudioQueuePlayer()
    private let apple = AVSpeechSynthesizer()
    @Published var playing = false
    @Published var message: String? = nil
    private var generation = 0

    func play() {
        generation += 1
        let gen = generation
        player.stop()
        apple.stopSpeaking(at: .immediate)
        playing = true; message = nil
        // The Apple engine has nothing to fetch: speak the same line through the system voice so the
        // button means the same thing on both engines.
        guard Settings.shared.ttsEngine == "gemini" else {
            let u = AVSpeechUtterance(string: Self.line)
            u.voice = AVSpeechSynthesisVoice(language: "en-GB") ?? AVSpeechSynthesisVoice(language: "en-US")
            u.rate = 0.5
            apple.speak(u)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(Double(Self.line.count) * 0.055 * 1e9))
                guard gen == generation else { return }
                playing = false
            }
            return
        }
        Task {
            if let audio = await TTS.synthesize(Self.line) {
                guard gen == generation else { return }
                player.play(audio) {
                    Task { @MainActor in
                        guard gen == self.generation else { return }
                        self.playing = false
                    }
                }
            } else {
                guard gen == generation else { return }
                playing = false
                message = (Settings.shared.geminiKey ?? "").isEmpty ? "Add a Gemini key to preview voices." : "Preview failed. Check the log."
            }
        }
    }

    func stop() { generation += 1; player.stop(); apple.stopSpeaking(at: .immediate); playing = false }
}

enum GeminiVoices {
    static let all = ["Zephyr", "Puck", "Charon", "Kore", "Fenrir", "Leda", "Orus", "Aoede", "Callirrhoe", "Autonoe",
                      "Enceladus", "Iapetus", "Umbriel", "Algieba", "Despina", "Erinome", "Algenib", "Rasalgethi",
                      "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima", "Achird", "Zubenelgenubi",
                      "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat"]
}

// MARK: - Helpers

extension String {
    /// First sentence of a tool description.
    var firstSentence: String {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"^.*?[.!?](\s|$)"#, options: .regularExpression) {
            return String(t[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }
}

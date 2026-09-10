import SwiftUI
import UniformTypeIdentifiers

/// Expanded content: transcript / response / chips / cards / composer.
struct NotchContent: View {
    @ObservedObject var model: NotchModel
    @ObservedObject private var settings = Settings.shared
    let controller: NotchController

    private var bodyCap: CGFloat { NotchController.maxHeight - 110 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            // Body scrolls only when it is taller than the cap; its true height is measured inside the scroll view
            // so the window can size itself from content rather than the other way round.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.priorTurns) { t in
                        PriorTurnView(turn: t)
                    }
                    if !model.transcript.isEmpty || model.phase == .listening {
                        TranscriptView(text: model.transcript, listening: model.phase == .listening, level: model.audioLevel)
                    }
                    if model.phase == .thinking && model.responseText.isEmpty && model.statusChips.isEmpty {
                        ThinkingLine()
                    }
                    if !model.responseText.isEmpty {
                        ResponseBubble(text: model.responseText, speaking: model.speaking)
                    }
                    if let err = model.errorText {
                        Text(err).font(Theme.text(13)).foregroundStyle(Theme.bad).padding(.horizontal, 4)
                    }
                    if !model.statusChips.isEmpty {
                        ChipsRow(chips: model.statusChips)
                    }
                    ForEach(model.cards) { card in
                        CardView(card: card, controller: controller)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    }
                    if model.showComposer {
                        ComposerView(model: model, controller: controller)
                    }
                }
            }
            .frame(maxHeight: bodyCap)
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.ink)
    }

    private var header: some View {
        HStack(spacing: 8) {
            NotchActivityMark(phase: model.phase, level: model.audioLevel,
                              working: model.statusChips.contains { $0.state == .running })
            Text(headerTitle)
                .font(Theme.text(12, .medium))
                .foregroundStyle(Theme.ink3)
            Spacer()
            if model.deepMode {
                Text("Deep")
                    .font(Theme.text(10, .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
            }
            Button { controller.collapse() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ink3)
                    .frame(width: 20, height: 20).background(Theme.fill1, in: Circle())
            }.buttonStyle(.plain).keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 2)
    }

    private var headerTitle: String {
        switch model.phase {
        case .idle: return model.showComposer ? "Type to Avo" : "Hold \(settings.talkKeyLabel) and talk"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .responding: return "Avo"
        case .done: return "Avo"
        case .error: return "Something went wrong"
        }
    }
}

/// The notch's activity indicator: a ring of twelve dots, drawn in one Canvas pass (no blur,
/// no shadow, no layers).
/// Every state is a different motion of the same ring. Listening: the voice pushes the dots
/// outward with a ripple travelling around the ring while a core swells in the centre. Thinking:
/// the ring turns with an undulating radius and one bright comet chasing round it. Responding:
/// a slow turn pulsing with the reply. Done: still, dim. Error: red. Clock-driven (TimelineView),
/// so it never inherits a stale repeatForever state and is paused when nothing moves.
struct NotchActivityMark: View {
    var phase: NotchModel.Phase
    var level: Float
    /// Accepted for call-site compatibility; tool activity is shown by the chips.
    var working: Bool = false
    var size: CGFloat = 18

    private var live: Bool { phase == .listening || phase == .thinking || phase == .responding }
    private static let dots = 12

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40.0, paused: !live)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let l = Double(min(max(level, 0), 1))
            Canvas { g, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                let base = sz.width * 0.37
                let tint: Color = phase == .error ? Theme.bad : Theme.accent
                for i in 0..<Self.dots {
                    let f = Double(i) / Double(Self.dots)
                    var a = f * 2 * .pi
                    var r = base
                    var alpha = 0.5
                    var dot = sz.width * 0.075
                    switch phase {
                    case .listening:
                        let ripple = (sin(a * 3 + t * 7) + 1) / 2
                        r = base + l * sz.width * 0.11 * (0.5 + 0.5 * ripple)
                        alpha = 0.4 + l * 0.6 * (0.4 + 0.6 * ripple)
                        dot = sz.width * (0.07 + l * 0.03)
                    case .thinking:
                        a += t * 1.1
                        r = base + sin(a * 2 - t * 4.2) * sz.width * 0.045
                        let comet = (f + t * 0.55).truncatingRemainder(dividingBy: 1)
                        let bright = pow(1 - comet, 2.2)
                        alpha = 0.18 + 0.82 * bright
                        dot = sz.width * (0.065 + 0.03 * bright)
                    case .responding:
                        a += t * 0.5
                        let pulse = (sin(t * 5.2) + 1) / 2
                        let phaseWave = (sin(a * 2 + t * 3) + 1) / 2
                        r = base + pulse * sz.width * 0.035
                        alpha = 0.3 + 0.7 * (0.5 * pulse + 0.5 * phaseWave)
                        dot = sz.width * (0.07 + 0.02 * pulse)
                    case .done:
                        alpha = 0.55
                    case .error:
                        alpha = 0.75
                    case .idle:
                        alpha = 0.3
                    }
                    let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                    // a faint larger disc under each dot gives a glow without a filter
                    g.fill(Path(ellipseIn: CGRect(x: p.x - dot * 1.1, y: p.y - dot * 1.1, width: dot * 2.2, height: dot * 2.2)),
                           with: .color(tint.opacity(alpha * 0.22)))
                    g.fill(Path(ellipseIn: CGRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot)),
                           with: .color(tint.opacity(alpha)))
                }
                // centre core: swells with the voice, breathes while thinking, beats while replying
                var core: Double = 0
                var coreAlpha = 0.9
                switch phase {
                case .listening: core = sz.width * (0.06 + l * 0.13)
                case .thinking: core = sz.width * (0.05 + 0.02 * (sin(t * 2.4) + 1) / 2); coreAlpha = 0.6
                case .responding: core = sz.width * (0.05 + 0.05 * (sin(t * 5.2) + 1) / 2); coreAlpha = 0.85
                default: break
                }
                if core > 0 {
                    g.fill(Path(ellipseIn: CGRect(x: c.x - core * 1.8, y: c.y - core * 1.8, width: core * 3.6, height: core * 3.6)),
                           with: .color(tint.opacity(coreAlpha * 0.18)))
                    g.fill(Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: core * 2, height: core * 2)),
                           with: .color(tint.opacity(coreAlpha)))
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Speech ribbon shown beside the mark while listening: three sine layers, each with its own
/// frequency and drift, tapered at both ends, amplitude from the mic. Idle amplitude is small
/// but never zero, so silence reads as a resting line, not a dead one.
struct VoiceRibbon: View {
    var level: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let l = 0.1 + Double(min(max(level, 0), 1)) * 0.9
            Canvas { g, size in
                let mid = size.height / 2
                let layers: [(amp: Double, freq: Double, speed: Double, alpha: Double, width: CGFloat)] = [
                    (1.0, 1.5, 2.6, 0.95, 1.6), (0.65, 2.4, -2.0, 0.5, 1.2), (0.4, 3.3, 3.4, 0.3, 1.0)
                ]
                let steps = max(8, Int(size.width / 1.5))
                for layer in layers {
                    var path = Path()
                    for i in 0...steps {
                        let x = Double(i) / Double(steps)
                        let envelope = sin(x * .pi)
                        let y = mid + sin(x * 2 * .pi * layer.freq + t * layer.speed) * (mid - 1) * l * layer.amp * envelope
                        let pt = CGPoint(x: x * size.width, y: y)
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    let shading = GraphicsContext.Shading.linearGradient(
                        Gradient(colors: [Theme.accent.opacity(0), Theme.accent.opacity(layer.alpha),
                                          Color(red: 0.42, green: 0.86, blue: 1.0).opacity(layer.alpha), Theme.accent.opacity(0)]),
                        startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
                    g.stroke(path, with: shading, style: StrokeStyle(lineWidth: layer.width, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

/// Rotating arc for status chips while a tool runs. Same language as the thinking mark.
struct SpinnerArc: View {
    var size: CGFloat = 10
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Circle().trim(from: 0, to: 0.66)
                .stroke(AngularGradient(colors: [Theme.accent.opacity(0), Theme.accent], center: .center, startAngle: .degrees(0), endAngle: .degrees(238)),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(t * 330))
        }
        .frame(width: size, height: size)
    }
}

struct TranscriptView: View {
    var text: String
    var listening: Bool
    var level: Float
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if listening { Waveform(level: level).frame(width: 26, height: 18).padding(.top, 3) }
            // The prompt is context, not the point: small and dim so the reply below reads first.
            Text(text.isEmpty ? "…" : text)
                .font(Theme.text(listening ? 15 : 13, .regular))
                .foregroundStyle(text.isEmpty ? Theme.ink3 : (listening ? Theme.ink : Theme.ink3))
                .lineLimit(listening ? 6 : 3)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.interpolate)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }
}

/// Mic-driven bars with a slow idle sway so they never look dead. Centre bars carry the level;
/// outer bars follow with a phase lag, so loud syllables ripple outward instead of jumping as one block.
/// Shared by the full transcript view (5 bars) and the compact listening strip (4 bars).
struct Waveform: View {
    var level: Float
    var bars: Int = 5
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2.5
    var maxHeight: CGFloat = 18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: spacing) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                        .frame(width: barWidth, height: height(i, t: t))
                        .shadow(color: Theme.accent.opacity(Double(min(level, 1)) * 0.5), radius: 2)
                }
            }
            .animation(.easeOut(duration: 0.09), value: level)
        }
        .frame(height: maxHeight)
    }

    private func height(_ i: Int, t: Double) -> CGFloat {
        let mid = Double(bars - 1) / 2
        let distance = abs(Double(i) - mid) / max(mid, 1)          // 0 at centre, 1 at edges
        let weight = 1 - distance * 0.55
        let sway = (sin(t * 2.3 + Double(i) * 1.1) + 1) / 2 * 2.5
        let l = Double(min(level, 1)) * (Double(maxHeight) - 4 - sway) * weight
        return CGFloat(min(Double(maxHeight), 4 + sway + l))
    }
}

struct IdleHint: View {
    @ObservedObject private var settings = Settings.shared
    var body: some View {
        HStack(spacing: 14) {
            hint(settings.talkKeyLabel, "hold to talk")
            hint(settings.composerShortcutLabel, "type")
            hint("esc", "cancel")
            Spacer()
            Button { NotchController.shared.presentComposer() } label: {
                Image(systemName: "keyboard").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink2)
                    .frame(width: 26, height: 26).background(Theme.fill1, in: Circle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
    }
    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key).font(Theme.text(11, .semibold)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Theme.fill2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(label).font(Theme.text(12)).foregroundStyle(Theme.ink3)
        }
    }
}

/// Thinking indicator: a bright comet glides along a thin track with a softer echo half a cycle
/// behind, eased so it accelerates out of the left edge and coasts into the right.
struct ThinkingLine: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fill2)
                    comet(width: w * 0.34, alpha: 0.95).offset(x: position(t / 1.15, width: w, span: 0.34))
                    comet(width: w * 0.2, alpha: 0.35).offset(x: position(t / 1.15 + 0.5, width: w, span: 0.2))
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 4)
    }

    /// Gradient capsule; the softer, wider twin underneath stands in for a glow without a filter.
    private func comet(width: CGFloat, alpha: Double) -> some View {
        ZStack {
            Capsule()
                .fill(LinearGradient(colors: [.clear, Theme.accent.opacity(alpha * 0.35), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: width * 1.5, height: 3)
            Capsule()
                .fill(LinearGradient(colors: [.clear, Theme.accent.opacity(alpha), Theme.accent.opacity(alpha), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: width)
        }
    }

    /// Smoothstep-eased sweep from fully off the left edge to fully off the right edge.
    private func position(_ cycle: Double, width: CGFloat, span: CGFloat) -> CGFloat {
        let p = cycle.truncatingRemainder(dividingBy: 1)
        let eased = p * p * (3 - 2 * p)
        return -width * span + CGFloat(eased) * width * (1 + span)
    }
}

/// An earlier turn of the open chat: the same transcript + bubble, dimmed so the live turn reads first.
struct PriorTurnView: View {
    var turn: NotchModel.PriorTurn
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.user)
                .font(Theme.text(13, .regular))
                .foregroundStyle(Theme.ink3)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
            ResponseBubble(text: turn.reply, speaking: false)
        }
        .opacity(0.78)
    }
}

struct ResponseBubble: View {
    var text: String
    var speaking: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            MarkdownView(source: text, baseFontSize: 15)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if speaking { Image(systemName: "speaker.wave.2.fill").font(.system(size: 11)).foregroundStyle(Theme.ink3).padding(.top, 3) }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Theme.fill1, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.8))
    }
}

struct ChipsRow: View {
    var chips: [NotchModel.StatusChip]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chips) { c in
                    HStack(spacing: 6) {
                        ChipIcon(icon: c.icon)
                        Text(c.label).font(Theme.text(12, .medium)).foregroundStyle(Theme.ink2)
                        ZStack {
                            switch c.state {
                            case .running:
                                SpinnerArc(size: 10)
                                    .transition(.opacity)
                            case .done:
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.good)
                                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                            case .failed:
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.bad)
                                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                            }
                        }
                        .frame(width: 10, height: 10)
                        .animation(Theme.springQuick, value: c.state)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.fill1, in: Capsule())
                    .overlay(Capsule().strokeBorder(c.state == .running ? Theme.accent.opacity(0.25) : Theme.line, lineWidth: 0.8))
                    .animation(Theme.springQuick, value: c.state)
                    .fixedSize()
                    .background(GeometryReader { g in Color.clear.preference(key: ChipFrameKey.self, value: [c.id: g.frame(in: .global)]) })
                }
            }
        }
        .frame(height: 26)
        .padding(.horizontal, 2)
        .onPreferenceChange(ChipFrameKey.self) { frames in NotchController.shared.chipFrames = frames }
    }
}

/// Where each chip sits in the hosting view, so the screenshot flight can land on the Screen chip.
struct ChipFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// Shows an app icon for "app:<bundle id>" or an SF symbol.
struct ChipIcon: View {
    var icon: String
    var size: CGFloat = 14
    var body: some View {
        if icon.hasPrefix("app:"), let img = AppIcons.icon(bundleId: String(icon.dropFirst(4))) {
            Image(nsImage: img).resizable().frame(width: size, height: size)
        } else if icon.hasPrefix("asset:") {
            Image(String(icon.dropFirst(6))).resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
        } else if icon.hasPrefix("img:"), let img = Thumbnails.image(path: String(icon.dropFirst(4))) {
            // A screenshot riding along with the request: a little picture of it, not a camera glyph.
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: size * 1.6, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        } else {
            Image(systemName: icon).font(.system(size: size - 3, weight: .semibold)).foregroundStyle(Theme.ink2)
                .frame(width: size, height: size)
        }
    }
}

enum Thumbnails {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 40
        return c
    }()
    /// Small copy of an image on disk (screenshots are ~1600 px wide; a chip needs 64).
    static func image(path: String) -> NSImage? {
        let key = path as NSString
        if let c = cache.object(forKey: key) { return c }
        guard let full = NSImage(contentsOfFile: path), full.size.width > 0 else { return nil }
        let w: CGFloat = 96, h = max(1, w * full.size.height / full.size.width)
        let small = NSImage(size: NSSize(width: w, height: h), flipped: false) { r in full.draw(in: r); return true }
        cache.setObject(small, forKey: key)
        return small
    }
}

enum AppIcons {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 50
        return c
    }()
    static func icon(bundleId: String) -> NSImage? {
        let key = bundleId as NSString
        if let c = cache.object(forKey: key) { return c }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: 32, height: 32)
        cache.setObject(img, forKey: key)
        return img
    }
}

struct ComposerView: View {
    @ObservedObject var model: NotchModel
    let controller: NotchController
    @FocusState private var focused: Bool
    @State private var dropTargeted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.attachments, id: \.self) { p in
                            AttachmentChip(path: p) { model.attachments.removeAll { $0 == p } }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                TextField(model.attachments.isEmpty ? "Ask Avo…" : "What about these?", text: $model.composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.text(14))
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit { submit() }
                Button { model.isChoosingAttachments = true } label: {
                    Image(systemName: "paperclip").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink3)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose attachments")
                .help("Choose images or files…")
                Button(action: submit) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(canSend ? Theme.accent : Theme.fill2, in: Circle())
                }.buttonStyle(.plain).disabled(!canSend).accessibilityLabel("Send request")
                Button { controller.collapse() } label: { EmptyView() }.buttonStyle(.plain).keyboardShortcut(.escape, modifiers: []).frame(width: 0, height: 0)
                // ⌘V: attach if the clipboard holds an image or file, otherwise normal text paste.
                Button { pasteSmart() } label: { EmptyView() }.buttonStyle(.plain).keyboardShortcut("v", modifiers: .command).frame(width: 0, height: 0)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.fill1, in: RoundedRectangle(cornerRadius: Theme.radiusField, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusField, style: .continuous).strokeBorder(dropTargeted ? Theme.accent : Theme.lineStrong, lineWidth: dropTargeted ? 1.2 : 0.8))
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
        .defaultFocus($focused, true)
        .fileImporter(isPresented: $model.isChoosingAttachments, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): addAttachments(urls)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    Log.warn("Attachment picker failed: \(error.localizedDescription)")
                }
            }
        }
        .fileDialogMessage("Choose files to include with your request.")
        .fileDialogConfirmationLabel("Attach")
    }
    private var canSend: Bool { !model.composerText.trimmingCharacters(in: .whitespaces).isEmpty || !model.attachments.isEmpty }
    private func submit() {
        let t = model.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let text = t.isEmpty ? "Look at what I attached." : t
        model.composerText = ""
        ContextBuilder.shared.pendingAttachments = model.attachments
        model.attachments = []
        model.showComposer = false
        Task { await AgentRuntime.shared.run(text: text) }
    }
    private func pasteSmart() {
        if !attachFromPasteboard() {
            if let s = NSPasteboard.general.string(forType: .string) { model.composerText += s }
        }
    }
    /// Pulls image/file items off the clipboard into attachments. Returns true if something was attached.
    @discardableResult
    private func attachFromPasteboard() -> Bool {
        let pb = NSPasteboard.general
        var added = false
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for u in urls where !model.attachments.contains(u.path) { model.attachments.append(u.path); added = true }
        } else if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let cg = rep.cgImage,
                  let path = ScreenCapture.shared.save(cg, name: "attach-pasted") {
            model.attachments.append(path); added = true
        }
        if added { Sounds.shared.play(.tick) }
        return added
    }
    private func addAttachments(_ urls: [URL]) {
        var added = false
        for url in urls where !model.attachments.contains(url.path) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            model.attachments.append(url.path)
            added = true
        }
        if added { Sounds.shared.play(.tick) }
    }
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var any = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier("public.file-url") {
                any = true
                p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    var url: URL?
                    if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) } else if let u = item as? URL { url = u }
                    if let u = url { DispatchQueue.main.async { if !model.attachments.contains(u.path) { model.attachments.append(u.path); Sounds.shared.play(.tick) } } }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                any = true
                p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let cg = rep.cgImage else { return }
                    if let path = ScreenCapture.shared.save(cg, name: "attach-dropped") { DispatchQueue.main.async { model.attachments.append(path); Sounds.shared.play(.tick) } }
                }
            }
        }
        return any
    }
}

struct AttachmentChip: View {
    var path: String
    var onRemove: () -> Void
    private var isImage: Bool { ["png","jpg","jpeg","gif","webp","heic","tiff"].contains((path as NSString).pathExtension.lowercased()) }
    var body: some View {
        HStack(spacing: 6) {
            if isImage, let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 20, height: 20)
            }
            Text((path as NSString).lastPathComponent).font(Theme.text(11, .medium)).foregroundStyle(Theme.ink2).lineLimit(1).frame(maxWidth: 140)
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.ink3) }.buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Theme.fill2, in: Capsule())
    }
}



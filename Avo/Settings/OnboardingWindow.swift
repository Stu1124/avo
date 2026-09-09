import AppKit
import SwiftUI

/// First-run flow: Welcome → Brain → Access → Try it → Extras → Ready. 1000×640, two panes: one
/// idea on the left, one thing to look at on the right. Every step is a label, a title, a sentence
/// and a single card — nothing else earns the space.
@MainActor
final class OnboardingWindow {
    static let shared = OnboardingWindow()
    static let size = NSSize(width: 1000, height: 640)
    private var window: NSWindow?
    private var closeObserver: Any?
    private let permissions = PermissionsModel()

    func show() {
        if window == nil {
            var root = OnboardingView(permissions: permissions, settings: Settings.shared,
                                      preview: VoicePreview.shared, notch: NotchController.shared.model) { [weak self] in
                self?.finish()
            }
            #if DEBUG
            // Verification seam: `defaults write app.avo.mac onboardingDebugStep -int 3` opens on that step.
            root.debugInitialStep = UserDefaults.standard.integer(forKey: "onboardingDebugStep")
            #endif
            let w = DarkWindow.make(title: "Welcome to Avo", size: Self.size, content: root)
            w.level = .floating
            // The flow paints its own ground, so the window's corner has to be the one the design
            // asks for rather than the system's default for a titled window.
            if let content = w.contentView {
                content.wantsLayer = true
                content.layer?.cornerRadius = 22
                content.layer?.cornerCurve = .continuous
                content.layer?.masksToBounds = true
            }
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.permissions.stop()
                    VoicePreview.shared.stop()
                }
            }
            window = w
        }
        permissions.start(interval: 1)
        DarkWindow.present(window!)
    }

    private func finish() {
        Settings.shared.onboarded = true
        Sounds.shared.play(.done)
        permissions.stop()
        window?.close()
        window = nil
        Log.info("Onboarding finished")
    }
}

struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var settings: Settings
    @ObservedObject var preview: VoicePreview
    /// The live notch model, mirrored on the "Try it" step so the first request is visible in place.
    @ObservedObject var notch: NotchModel
    var onFinish: () -> Void
    #if DEBUG
    /// Preview seam: which step to open on. Never set outside verification.
    var debugInitialStep = 0
    #endif

    enum Step: Int, CaseIterable {
        case welcome, brain, permissions, tryIt, extras, ready
        /// Small-caps eyebrow under the progress bar.
        var label: String {
            switch self {
            case .welcome: return "Welcome"
            case .brain: return "Brain"
            case .permissions: return "Access"
            case .tryIt: return "Try it"
            case .extras: return "Extras"
            case .ready: return "Ready"
            }
        }
    }

    /// The left pane is 46% of a 1000 pt window; the stage takes the rest. The margin is wide on
    /// purpose — the whitespace is the design.
    private static let leftWidth: CGFloat = 460
    private static let pad: CGFloat = 44
    /// Content travels 12 pt and fades on one unhurried, critically damped spring.
    private static let stepSpring = Animation.spring(response: 0.45, dampingFraction: 0.95)

    @State private var step = 0
    @State private var forward = true
    /// Puts the caret in the Brain step's first field as soon as that step arrives.
    @FocusState private var baseURLFocused: Bool
    /// Result of the Brain step's Test, mirrored onto the stage. Nil until Test has been pressed.
    @State private var keyVerified: Bool? = nil

    // Extras step
    @State private var googleBusy = false
    @State private var googleEmail: String? = nil
    @State private var googleError: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var steps: Int { Step.allCases.count }
    private var current: Step { Step(rawValue: step) ?? .welcome }

    /// Enter and exit run along the same axis, so Back retraces the path Continue took.
    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        let d: CGFloat = forward ? 12 : -12
        return .asymmetric(insertion: .offset(x: d).combined(with: .opacity),
                           removal: .offset(x: -d).combined(with: .opacity))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // The pane takes the window's full height whatever the step measures, so the progress
            // bar and the footer sit at the same y on every step.
            leftPane.frame(width: Self.leftWidth).frame(maxHeight: .infinity)
            OnboardingStage(step: current, settings: settings, permissions: permissions,
                            notch: notch, googleEmail: googleEmail, keyVerified: keyVerified, run: run)
                .padding(.trailing, 36)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(OnboardingBackground())
        .onAppear {
            // Reads the Keychain on the main actor. Safe here and only here: onboarding has a visible
            // window by definition, so a legacy item's access prompt can be answered. The rule this
            // does not break is the launch path — see Settings.bootstrapSecretsFromDisk.
            googleEmail = GoogleAuth.shared.isConnected ? GoogleAuth.shared.email : nil
            #if DEBUG
            if step == 0, debugInitialStep != 0 { step = debugInitialStep }
            #endif
            focusBrainField()
        }
    }

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            SegmentedProgress(count: steps, index: step)
            Text(current.label.uppercased())
                .font(DS.font(DS.Size.label, .semibold)).tracking(1.1).foregroundStyle(Theme.accent)
                .padding(.top, DS.Space.m)
            ZStack(alignment: .topLeading) {
                Group {
                    switch current {
                    case .welcome: welcome
                    case .brain: brainStep
                    case .permissions: permissionsStep
                    case .tryIt: tryItStep
                    case .extras: extrasStep
                    case .ready: ready
                    }
                }
                .id(step)
                .transition(transition)
            }
            .padding(.top, DS.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            footer
        }
        .padding(.horizontal, Self.pad)
        .padding(.top, 40)
        .padding(.bottom, 36)
    }

    private func go(_ delta: Int) {
        let next = max(0, min(steps - 1, step + delta))
        guard next != step else { return }
        forward = delta > 0
        if current == .extras { preview.stop() }
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : Self.stepSpring) { step = next }
        focusBrainField()
    }

    /// SwiftUI can only hand focus to a field once the window is key and the step's view exists, so
    /// land the caret after the transition. The step is read again inside the closure: 0.35 s is
    /// long enough for Back or ⌘↩ to have moved on, and focusing a field that is no longer on screen
    /// would take focus away from whatever is.
    private func focusBrainField() {
        guard current == .brain else { baseURLFocused = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard current == .brain else { return }
            baseURLFocused = true
        }
    }

    // MARK: Footer

    /// Microphone and Speech Recognition are the two the hold-to-talk loop cannot work without;
    /// Input Monitoring and Accessibility can be granted later.
    private var canLeavePermissions: Bool {
        permissions.status[.microphone] == .granted && permissions.status[.speechRecognition] == .granted
    }
    private var blocked: Bool { current == .permissions && !canLeavePermissions }
    private var primaryLabel: String {
        switch current {
        case .welcome: return "Get started"
        case .ready: return "Finish"
        default: return "Continue"
        }
    }

    private var footer: some View {
        HStack(spacing: DS.Space.s) {
            if step > 0 { BigButton(label: "Back", style: .ghost) { go(-1) } }
            Spacer(minLength: DS.Space.s)
            KeyCap(text: "⌘ ↩").opacity(blocked ? 0.25 : 0.5)
            BigButton(label: primaryLabel) { advance() }
                .disabled(blocked)
                .opacity(blocked ? 0.45 : 1)
                .keyboardShortcut(.return, modifiers: .command)
                .animation(Theme.springQuick, value: blocked)
        }
        .padding(.top, DS.Space.xl)
        .background(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .background {
            // ↩ commits and ⌘← goes back, without either taking a visible place in the footer.
            Group {
                Button("") { advance() }.keyboardShortcut(.return, modifiers: []).disabled(blocked)
                Button("") { go(-1) }.keyboardShortcut(.leftArrow, modifiers: .command).disabled(step == 0)
            }
            .opacity(0).frame(width: 0, height: 0)
        }
    }

    private func advance() { current == .ready ? onFinish() : go(1) }

    // MARK: Shared bits

    /// Title, one sentence, one card. This is the only layout any step gets. Large text takes
    /// negative tracking and tight leading; the body sits near zero.
    private func page<C: View>(_ title: String, _ subtitle: String, @ViewBuilder _ card: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text(title).font(DS.font(DS.Size.hero, .semibold)).foregroundStyle(Theme.ink)
                    .tracking(-1.2).lineSpacing(-2).fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(DS.font(DS.Size.lead)).foregroundStyle(Theme.ink2).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            card()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A single-block card, for steps whose content is not a list of rows. Same surface as
    /// `SectionCard`, which is where `cardChrome` is defined.
    private func panel<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content().padding(DS.Space.l).frame(maxWidth: .infinity, alignment: .leading).cardChrome()
    }

    private var talkKeyCap: some View {
        KeyCap(text: settings.talkKeyLabel, symbol: settings.talkKey == "fn" ? "globe" : nil)
    }

    // MARK: 1 · Welcome

    private var welcome: some View {
        page("Hold. Speak. Done.",
             "Hold \(settings.talkKeyLabel) anywhere, say what you want, and Avo does it.") {
            panel {
                HStack(spacing: DS.Space.s) {
                    talkKeyCap
                    Text("or").font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3)
                    KeyCap(text: "⌃ ⌥")
                    Text("hold to talk, tap to type")
                        .font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3)
                        .padding(.leading, DS.Space.xs)
                }
            }
        }
    }

    // MARK: 2 · Brain

    private var brainStep: some View {
        page("Pick a brain.", "OpenAI with a key, or any OpenAI-compatible server.") {
            SectionCard {
                PickerRow(title: "Provider", selection: styleBinding, options: GeneralPage.styleOptions)
                TextRow(title: "Base URL", placeholder: "https://api.openai.com/v1", text: $settings.apiBaseURL, width: 176, focused: $baseURLFocused)
                KeyField(provider: .openAI) { ok in withAnimation(Theme.springQuick) { keyVerified = ok } }
                TextRow(title: "Model", placeholder: "model id", text: $settings.brainModel, width: 176)
            }
        }
    }

    /// Anything that is not the Responses style reads as "OpenAI-compatible" in the picker.
    private var styleBinding: Binding<String> {
        Binding(get: { settings.apiStyle == "responses" ? "responses" : "chat" }, set: { settings.apiStyle = $0 })
    }

    // MARK: 3 · Access

    private var permissionsStep: some View {
        page("Four permissions.", "Microphone and Speech Recognition are required — macOS asks once.") {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                VStack(spacing: 0) {
                    ForEach(Array(PermissionKind.upFront.enumerated()), id: \.element.id) { i, k in
                        if i > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 50) }
                        OnboardingPermissionRow(kind: k, model: permissions)
                    }
                }
                .cardChrome()
                Text("Everything else is asked later, the first time something needs it.")
                    .font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 4 · Try it

    private var tryItStep: some View {
        page("Say something.", "Hold \(settings.talkKeyLabel) and say “what time is it”.") {
            panel {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    HStack(spacing: DS.Space.s) {
                        talkKeyCap
                        Text("hold and say").font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3)
                        Spacer(minLength: DS.Space.s)
                        DSPill("Type it instead", icon: "keyboard") { run("what time is it") }
                    }
                    Text("“what time is it”").font(DS.font(DS.Size.lead, .medium)).foregroundStyle(Theme.ink)
                }
            }
        }
    }

    /// Runs a request exactly the way a released talk key does, so the notch shows the real thing
    /// and the stage mirrors it.
    private func run(_ text: String) {
        NotchController.shared.presentTurn(text)
        Task { await AgentRuntime.shared.run(text: text) }
    }

    // MARK: 5 · Extras

    private var extrasStep: some View {
        page("Two extras.", "Both optional, both changeable later in Settings.") {
            SectionCard(footer: googleError) {
                ActionRow(title: googleEmail ?? "Google", subtitle: googleEmail == nil ? "Gmail, Calendar and Drive" : "Connected", icon: "globe") {
                    if googleEmail == nil {
                        DSPill("Connect", icon: "arrow.up.forward", style: .primary, busy: googleBusy) { connectGoogle() }
                    } else {
                        DSPill("Disconnect", style: .ghost) { GoogleAuth.shared.signOut(); googleEmail = nil }
                    }
                }
                ActionRow(title: "Speak replies", subtitle: "Read the one-line reply aloud", icon: "speaker.wave.2.fill") {
                    Toggle("", isOn: $settings.speakReplies).labelsHidden().toggleStyle(DSToggleStyle())
                    DSPill(preview.playing ? "Playing" : "Preview", icon: preview.playing ? nil : "play.fill", busy: preview.playing) {
                        preview.play()
                    }
                }
            }
        }
    }

    private func connectGoogle() {
        googleBusy = true; googleError = nil
        Task {
            do {
                let e = try await GoogleAuth.shared.signIn()
                withAnimation(Theme.springQuick) { googleEmail = e }
                Sounds.shared.play(.done)
            } catch {
                googleError = error.localizedDescription
                Sounds.shared.play(.error)
            }
            googleBusy = false
        }
    }

    // MARK: 6 · Ready

    private var ready: some View {
        page("You're set.", "Avo lives in your menu bar and under the notch.") {
            VStack(spacing: 0) {
                whereRow("menubar.rectangle", "Menu bar", "Status, history and Settings.")
                Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 50)
                whereRow("rectangle.topthird.inset.filled", "The notch", "Where every reply lands.")
            }
            .cardChrome()
        }
    }

    private func whereRow(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: DS.Space.m) {
            GroupIcon(icon: icon, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.font(DS.Size.body, .medium)).foregroundStyle(Theme.ink)
                Text(subtitle).font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
    }
}

/// The flow's ground: a near-black base with one large, soft accent glow anchored off the top-left
/// corner — the same light the app icon tile is lit by — and a hairline that draws the window edge.
struct OnboardingBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.027, green: 0.035, blue: 0.051)
            RadialGradient(colors: [Theme.accent.opacity(0.10), Theme.accent.opacity(0.035), .clear],
                           center: UnitPoint(x: 0.04, y: -0.06), startRadius: 0, endRadius: 700)
            LinearGradient(colors: [.clear, Color.black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
        .ignoresSafeArea()
    }
}

/// Compact permission row for the onboarding left pane: name, state and the one control.
private struct OnboardingPermissionRow: View {
    let kind: PermissionKind
    @ObservedObject var model: PermissionsModel
    var body: some View {
        let st = model.status[kind] ?? .unknown
        HStack(spacing: DS.Space.m) {
            Image(systemName: kind.icon).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(st == .granted ? Theme.accent : Theme.ink2)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(st == .granted ? Theme.accent.opacity(0.16) : Theme.fill2))
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).font(DS.font(DS.Size.body, .medium)).foregroundStyle(Theme.ink)
                Text(model.label(kind)).font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3)
            }
            Spacer(minLength: DS.Space.s)
            if st == .granted {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.good)
                    .frame(width: 62, alignment: .trailing)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else {
                DSPill(st == .notDetermined ? "Grant" : "Open", style: .primary) { kind.request() }
                    .frame(width: 62, alignment: .trailing)
            }
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, 10)
        .animation(Theme.springQuick, value: st)
    }
}

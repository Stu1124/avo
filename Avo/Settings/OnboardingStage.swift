import SwiftUI

/// The right-hand half of onboarding: one framed surface per step, and exactly one thing on it.
/// What it draws is either the live state of the app — permissions, the notch, the provider
/// settings — or a mock that reads plainly as one. Nothing here acts except the Ready step's pills.
///
/// Steps cross-fade: the frame stays put and only its contents change, so the eye keeps its place.
struct OnboardingStage: View {
    var step: OnboardingView.Step
    @ObservedObject var settings: Settings
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var notch: NotchModel
    var googleEmail: String?
    var keyVerified: Bool?
    var run: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StageFrame {
            Group {
                switch step {
                case .welcome: WelcomeStage(settings: settings)
                case .brain: BrainStage(settings: settings, verified: keyVerified)
                case .permissions: AccessStage(permissions: permissions)
                case .tryIt: TryItStage(settings: settings, notch: notch)
                case .extras: ExtrasStage(settings: settings, googleEmail: googleEmail)
                case .ready: ReadyStage(run: run)
                }
            }
            .id(step)
            .transition(.opacity)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.3), value: step)
    }
}

// MARK: - Stage chrome

/// The framed dark surface every stage is drawn on: a deeper ground than the window's, lit along
/// its top edge so it reads as a panel in front of the glow rather than a hole in it.
struct StageFrame<Content: View>: View {
    static var radius: CGFloat { 20 }
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(Color.black.opacity(0.34))
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                            .fill(LinearGradient(colors: [Color.white.opacity(0.045), .clear], startPoint: .top, endPoint: .center))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.13), Color.white.opacity(0.03)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
    }
}

/// A panel inside the stage — one shade lighter than the stage floor, hairlined, and lit in the
/// accent when whatever it stands for is on.
struct StagePanel<Content: View>: View {
    var padding: CGFloat = DS.Space.m
    var lit = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(lit ? Theme.accent.opacity(0.10) : Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(lit ? Theme.accent.opacity(0.45) : Theme.line, lineWidth: 0.8))
            .shadow(color: lit ? Theme.accent.opacity(0.28) : .clear, radius: 14)
    }
}

/// Mic bars that hold still under Reduce Motion instead of swaying forever.
struct StageWave: View {
    var level: Float = 0.72
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            HStack(spacing: 2.5) {
                ForEach([0.45, 0.8, 1.0, 0.7, 0.35], id: \.self) { f in
                    Capsule().fill(Theme.accent.opacity(0.85)).frame(width: 3, height: max(4, 18 * f))
                }
            }
            .frame(height: 18)
        } else {
            Waveform(level: level, maxHeight: 18).frame(width: 26, height: 18)
        }
    }
}

/// The reply surface the notch uses, reproduced at stage scale.
struct StageReply: View {
    var text: String
    var body: some View {
        MarkdownView(source: text, baseFontSize: 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(Theme.fill1, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 0.8))
    }
}

/// The top of a display: a menu bar with the notch cut out of it, and Avo's panel hanging under the
/// notch the way it does on a real Mac. It fills the stage, so the room around the panel reads as
/// the desktop rather than as a gap in the layout.
struct NotchMock<Content: View>: View {
    var panelWidth: CGFloat = 350
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.05)).frame(height: 24)
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
                    .fill(Color.black).frame(width: 124, height: 22)
            }
            content
                .padding(13)
                .frame(width: panelWidth, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: Theme.radiusNotch, style: .continuous)
                        .fill(Theme.glass)
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.radiusNotch, style: .continuous)
                                .fill(LinearGradient(colors: [Color.white.opacity(0.06), .clear], startPoint: .top, endPoint: .bottom))
                        }
                }
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusNotch, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.55), radius: 18, y: 9)
                .padding(.top, -4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(LinearGradient(colors: [Color.white.opacity(0.055), Color.white.opacity(0.012)],
                                   startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.8))
    }
}

#if DEBUG
/// Verification seam: pins the Welcome loop to one beat, so an off-screen render is not a race with
/// a timer. Never set outside `DebugPreviews`.
@MainActor enum OnboardingStagePreview { static var beat: Int? = nil }
#endif

/// The notch at stage scale: what Avo is doing, what you said, what came back. The Welcome loop and
/// the live Try-it mirror are this same view with different values — one is a script, one is the
/// real model.
private struct NotchStage: View {
    @ObservedObject var settings: Settings
    var phase: NotchModel.Phase
    var title: String
    var level: Float = 0
    var transcript = ""
    var reply = ""
    var error: String? = nil
    var thinking = false
    /// Shows the talk-key hint in place of a transcript, for when there is nothing to show yet.
    var hint = false

    private var listening: Bool { phase == .listening }

    var body: some View {
        NotchMock {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    NotchActivityMark(phase: phase, level: level, size: 15)
                    Text(title).font(Theme.text(11, .medium)).foregroundStyle(Theme.ink3)
                    Spacer(minLength: 0)
                }
                if hint {
                    HStack(spacing: DS.Space.s) {
                        KeyCap(text: settings.talkKeyLabel, symbol: settings.talkKey == "fn" ? "globe" : nil)
                        Text("hold to talk").font(Theme.text(12)).foregroundStyle(Theme.ink3)
                        Spacer(minLength: 0)
                    }
                } else if !transcript.isEmpty || listening {
                    HStack(alignment: .top, spacing: 10) {
                        if listening { StageWave(level: level) }
                        Text(transcript.isEmpty ? "…" : transcript)
                            .font(Theme.text(listening ? 14 : 12))
                            .foregroundStyle(listening ? Theme.ink : Theme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
                if !reply.isEmpty { StageReply(text: reply) } else if thinking { ThinkingLine() }
                if let error {
                    Text(error).font(Theme.text(12)).foregroundStyle(Theme.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
            .animation(Theme.springCard, value: transcript)
            .animation(Theme.springCard, value: reply)
        }
        .frame(height: 306)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

// MARK: - 1 · Welcome

/// One whole request, looping, in the place a real one happens: hold the key, Avo hears you, the
/// words appear, and the reply lands. The loop is the whole stage.
private struct WelcomeStage: View {
    @ObservedObject var settings: Settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beat = 0

    private static let beats = 4
    private static let said = "Text Sam I'm running late"
    private static let tick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        loop
            .onAppear {
                #if DEBUG
                if let b = OnboardingStagePreview.beat { beat = min(b, Self.beats - 1); return }
                #endif
                if reduceMotion { beat = Self.beats - 1 }
            }
            .onReceive(Self.tick) { _ in
                #if DEBUG
                if OnboardingStagePreview.beat != nil { return }
                #endif
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { beat = (beat + 1) % Self.beats }
            }
    }

    @ViewBuilder private var loop: some View {
        switch beat {
        case 0: NotchStage(settings: settings, phase: .idle, title: "Hold \(settings.talkKeyLabel) and speak", hint: true)
        case 1: NotchStage(settings: settings, phase: .listening, title: "Listening", level: 0.7)
        case 2: NotchStage(settings: settings, phase: .listening, title: "Listening", level: 0.5, transcript: Self.said)
        default: NotchStage(settings: settings, phase: .done, title: "Avo", transcript: Self.said,
                            reply: "Sent to Sam.")
        }
    }
}

// MARK: - 2 · Brain

/// One card: the host Avo will call, the model it will ask for, and whether Test has proved the key.
/// The dot stays grey until Test has run — a green light before anyone pressed anything would be
/// claiming a result Avo does not have.
private struct BrainStage: View {
    @ObservedObject var settings: Settings
    var verified: Bool?

    private var host: String {
        let path = settings.apiStyle == "responses" ? "responses" : "chat/completions"
        return ProviderURL.endpoint(path, base: settings.apiBaseURL).host ?? "api.openai.com"
    }
    private var model: String { settings.brainModel.isEmpty ? "model-id" : settings.brainModel }

    var body: some View {
        StagePanel(padding: DS.Space.xl, lit: verified == true) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text(host).font(DS.mono(16, .semibold)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                Text(model).font(DS.mono(13)).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle)
                HStack(spacing: DS.Space.s) {
                    StatusDot(state: verified == nil ? .off : (verified == true ? .ok : .bad))
                    Text(verified == nil ? "Not tested yet" : (verified == true ? "Key verified" : "Test failed"))
                        .font(DS.font(DS.Size.caption, .medium)).foregroundStyle(Theme.ink3)
                }
                .padding(.top, DS.Space.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(Theme.springCard, value: verified)
    }
}

// MARK: - 3 · Access

/// The same four permissions the left pane grants, with the reason each is asked for. A tile lights
/// the moment the poll sees the grant, so the answer to a system prompt shows up here.
private struct AccessStage: View {
    @ObservedObject var permissions: PermissionsModel

    var body: some View {
        // Two hand-built rows rather than a grid: the tiles have to share the stage's height evenly,
        // and a lazy grid sizes its rows to their content instead.
        VStack(spacing: DS.Space.l) {
            ForEach(0..<2, id: \.self) { row in
                HStack(alignment: .top, spacing: DS.Space.l) {
                    ForEach(PermissionKind.upFront[(row * 2)..<(row * 2 + 2)], id: \.id) { kind in
                        tile(kind).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func tile(_ kind: PermissionKind) -> some View {
        let on = permissions.status[kind] == .granted
        return StagePanel(padding: DS.Space.l, lit: on) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: kind.icon).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(on ? Theme.accent : Theme.ink2)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(on ? Theme.accent.opacity(0.18) : Color.white.opacity(0.06)))
                    Spacer(minLength: 0)
                    Image(systemName: on ? "checkmark" : "minus").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(on ? Theme.good : Theme.ink3)
                }
                Text(kind.title).font(DS.font(DS.Size.body, .semibold)).foregroundStyle(Theme.ink)
                Text(kind.detail)
                    .font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 96, alignment: .top)
        }
        .animation(Theme.springCard, value: on)
    }
}

// MARK: - 4 · Try it

/// The live notch, mirrored, and nothing else: the waveform follows the microphone, the transcript
/// is what the recognizer heard, the reply is what streamed back.
private struct TryItStage: View {
    @ObservedObject var settings: Settings
    @ObservedObject var notch: NotchModel

    private var idle: Bool {
        notch.transcript.isEmpty && notch.responseText.isEmpty && notch.errorText == nil
            && notch.phase != .listening && notch.phase != .thinking
    }
    private var title: String {
        switch notch.phase {
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        default: return idle ? "Waiting" : "Avo"
        }
    }

    var body: some View {
        NotchStage(settings: settings, phase: notch.phase, title: title, level: notch.audioLevel,
                   transcript: notch.transcript, reply: notch.responseText, error: notch.errorText,
                   thinking: notch.phase == .thinking, hint: idle)
    }
}

// MARK: - 5 · Extras

/// Two tiles: what each extra is, and where it stands right now.
private struct ExtrasStage: View {
    @ObservedObject var settings: Settings
    var googleEmail: String?

    var body: some View {
        VStack(spacing: DS.Space.l) {
            tile("globe", "Google", on: googleEmail != nil, state: googleEmail == nil ? "Off" : "Connected",
                 detail: "Gmail, Calendar and Drive through your own account.")
            tile("speaker.wave.2.fill", "Spoken replies", on: settings.speakReplies,
                 state: settings.speakReplies ? "On" : "Off",
                 detail: "Reads the one-line reply aloud after each request.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func tile(_ icon: String, _ title: String, on: Bool, state: String, detail: String) -> some View {
        StagePanel(padding: DS.Space.xl, lit: on) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(on ? Theme.accent : Theme.ink2)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(on ? Theme.accent.opacity(0.18) : Color.white.opacity(0.06)))
                    Text(title).font(DS.font(DS.Size.lead, .semibold)).foregroundStyle(Theme.ink)
                    Spacer(minLength: DS.Space.s)
                    StatusLabel(state: on ? .ok : .off, text: state)
                }
                Text(detail).font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Theme.springCard, value: on)
    }
}

// MARK: - 6 · Ready

/// The mark, breathing, and three requests that work right now. Clicking one runs it for real.
private struct ReadyStage: View {
    var run: (String) -> Void

    private static let examples = ["Text Sam I'm running late",
                                   "What's on my calendar tomorrow",
                                   "Remind me to stretch in 20 minutes"]

    var body: some View {
        VStack(spacing: DS.Space.l) {
            Spacer(minLength: 0)
            AvoMark(size: 120, animated: true)
            Spacer(minLength: 0)
            VStack(spacing: DS.Space.s) {
                ForEach(Self.examples, id: \.self) { e in ExamplePill(text: e) { run(e) } }
            }
            Text("Speech stays on this Mac. Avo sends your request text to the model you chose.")
                .font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3).lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One runnable example. Presses in on pointer-down, the way a real button does.
private struct ExamplePill: View {
    let text: String
    var action: () -> Void
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                Text("“\(text)”").font(DS.font(DS.Size.body)).foregroundStyle(Theme.ink)
                Spacer(minLength: DS.Space.s)
                Image(systemName: "arrow.up.forward").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ink4)
            }
            .padding(.horizontal, DS.Space.l).padding(.vertical, 11)
            .background(Capsule().fill(pressed ? Theme.accent.opacity(0.20) : Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(pressed ? Theme.accent.opacity(0.5) : Theme.line, lineWidth: 0.8))
            .contentShape(Capsule())
            .scaleEffect(pressed && !reduceMotion ? 0.985 : 1, anchor: .leading)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0, pressing: { p in
            withAnimation(reduceMotion ? nil : Theme.springQuick) { pressed = p }
        }, perform: {})
    }
}

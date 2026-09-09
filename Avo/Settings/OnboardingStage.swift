import SwiftUI

/// The right-hand half of onboarding: one framed surface per step that shows what the step is
/// about. Nothing here takes an action of its own except the Ready step's example pills — the
/// stage's job is to make the step legible, and everything it draws is either the live state of
/// the app (permissions, the notch, the provider settings) or a mock clearly labelled as one.
///
/// Steps cross-fade: the frame stays put and only its contents change, so the eye keeps its place.
struct OnboardingStage: View {
    var step: OnboardingView.Step
    @ObservedObject var settings: Settings
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var notch: NotchModel
    @ObservedObject var preview: VoicePreview
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
                case .extras: ExtrasStage(settings: settings, preview: preview, googleEmail: googleEmail)
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
/// its top edge so it reads as a panel sitting in front of the glow rather than a hole in it.
struct StageFrame<Content: View>: View {
    static var radius: CGFloat { 20 }
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(Color.black.opacity(0.34))
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                            .fill(LinearGradient(colors: [Color.white.opacity(0.045), .clear],
                                                 startPoint: .top, endPoint: .center))
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

/// Small-caps heading that says what the stage is showing. One per stage, never more.
struct StageHeading: View {
    var text: String
    var trailing: String? = nil
    var body: some View {
        HStack(spacing: DS.Space.s) {
            Text(text.uppercased()).font(DS.font(DS.Size.label, .semibold)).tracking(1.1).foregroundStyle(Theme.ink3)
            Spacer(minLength: DS.Space.s)
            if let trailing {
                Text(trailing).font(DS.font(DS.Size.label, .medium)).tracking(0.5).foregroundStyle(Theme.ink3)
            }
        }
    }
}

/// A panel inside the stage — one shade lighter than the stage floor, hairlined.
struct StagePanel<Content: View>: View {
    var radius: CGFloat = 14
    var padding: CGFloat = DS.Space.m
    var lit = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(lit ? Theme.accent.opacity(0.10) : Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(lit ? Theme.accent.opacity(0.45) : Theme.line, lineWidth: 0.8))
            .shadow(color: lit ? Theme.accent.opacity(0.28) : .clear, radius: 14)
    }
}

/// Mic bars that hold still under Reduce Motion instead of swaying forever.
struct StageWave: View {
    var level: Float = 0.72
    var height: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            HStack(spacing: 2.5) {
                ForEach([0.45, 0.8, 1.0, 0.7, 0.35], id: \.self) { f in
                    Capsule().fill(Theme.accent.opacity(0.85))
                        .frame(width: 3, height: max(4, height * f))
                }
            }
            .frame(height: height)
        } else {
            Waveform(level: level, maxHeight: height).frame(width: 26, height: height)
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
/// notch the way it does on a real Mac. The surface fills whatever room the stage gives it, so the
/// space around the panel reads as the desktop rather than as a gap in the layout.
struct NotchMock<Content: View>: View {
    var panelWidth: CGFloat = 340
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 24)
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 7) {
                            ForEach(0..<3, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(Color.white.opacity(0.14)).frame(width: 9, height: 9)
                            }
                        }
                        .padding(.trailing, 12)
                    }
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 124, height: 22)
            }
            content
                .padding(13)
                .frame(width: panelWidth, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: Theme.radiusNotch, style: .continuous)
                        .fill(Theme.glass)
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.radiusNotch, style: .continuous)
                                .fill(LinearGradient(colors: [Color.white.opacity(0.06), .clear],
                                                     startPoint: .top, endPoint: .bottom))
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

/// Header line inside the notch mock: the activity mark and what Avo is doing.
struct NotchMockHeader: View {
    var phase: NotchModel.Phase
    var title: String
    var level: Float = 0
    var body: some View {
        HStack(spacing: 7) {
            NotchActivityMark(phase: phase, level: level, size: 15)
            Text(title).font(Theme.text(11, .medium)).foregroundStyle(Theme.ink3)
            Spacer(minLength: 0)
        }
    }
}

#if DEBUG
/// Verification seam: pins the Welcome stage's loop to one beat, so an off-screen render is not a
/// race with a timer. Never set outside `DebugPreviews`.
@MainActor enum OnboardingStagePreview { static var beat: Int? = nil }
#endif

// MARK: - 1 · Welcome

/// A 7 s loop through one whole request, in the place a real one happens: hold the key, Avo hears
/// you, the words appear, anything that sends shows a card first, then the reply.
private struct WelcomeStage: View {
    @ObservedObject var settings: Settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beat = 0

    private static let beats = 5
    private static let captions = ["Hold the key.", "Avo hears you.", "Your words, transcribed here.",
                                   "Anything that sends asks first.", "Done — and said back."]
    private static let tick = Timer.publish(every: 1.4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StageHeading(text: "One request, start to finish")
                .padding(.bottom, DS.Space.m)
            NotchMock { panelContent }
                .frame(minHeight: 250)
                .padding(.bottom, DS.Space.l)
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: 5) {
                    ForEach(0..<Self.beats, id: \.self) { i in
                        Capsule().fill(i == beat ? Theme.accent : Color.white.opacity(0.10))
                            .frame(height: 2.5)
                    }
                }
                Text(Self.captions[min(beat, Self.captions.count - 1)])
                    .font(DS.font(DS.Size.caption, .medium)).foregroundStyle(Theme.ink2)
                    .animation(nil, value: beat)
            }
            Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, DS.Space.l)
            VStack(alignment: .leading, spacing: DS.Space.m) {
                fact("app.badge.checkmark", "It acts in your apps", "Messages, Reminders, Calendar, Finder, your browser.")
                fact("rectangle.on.rectangle", "It can look at your screen", "Only when the question is about what you're looking at.")
                fact("lock.shield", "Nothing runs behind your back", "Sends, creates and deletes show a card you approve.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            #if DEBUG
            if let b = OnboardingStagePreview.beat { beat = b; return }
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

    @ViewBuilder private var panelContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch beat {
            case 0:
                NotchMockHeader(phase: .idle, title: "Hold \(settings.talkKeyLabel) and talk")
                HStack(spacing: DS.Space.s) {
                    KeyCap(text: settings.talkKeyLabel, symbol: settings.talkKey == "fn" ? "globe" : nil)
                    Text("hold to talk").font(Theme.text(12)).foregroundStyle(Theme.ink3)
                    Spacer(minLength: 0)
                }
            case 1:
                NotchMockHeader(phase: .listening, title: "Listening", level: 0.7)
                HStack(alignment: .center, spacing: 10) {
                    StageWave()
                    Text("…").font(Theme.text(14)).foregroundStyle(Theme.ink3)
                    Spacer(minLength: 0)
                }
            case 2:
                NotchMockHeader(phase: .listening, title: "Listening", level: 0.5)
                HStack(alignment: .top, spacing: 10) {
                    StageWave()
                    Text("Text Sam I'm running late")
                        .font(Theme.text(14)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            case 3:
                NotchMockHeader(phase: .thinking, title: "Avo")
                Text("Text Sam I'm running late").font(Theme.text(12)).foregroundStyle(Theme.ink3)
                confirmationMock
            default:
                NotchMockHeader(phase: .done, title: "Avo")
                Text("Text Sam I'm running late").font(Theme.text(12)).foregroundStyle(Theme.ink3)
                StageReply(text: "Sent. Sam knows you're about ten minutes out.")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
    }

    private var confirmationMock: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "message.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.86, blue: 0.45), Color(red: 0.18, green: 0.7, blue: 0.30)],
                                             startPoint: .top, endPoint: .bottom)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Send iMessage").font(Theme.text(12, .semibold)).foregroundStyle(Theme.ink)
                    Text("to Sam").font(Theme.text(10)).foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 0)
            }
            Text("Running about ten minutes late — start without me.")
                .font(Theme.text(11)).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.s).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.3)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.8))
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Text("Cancel").font(Theme.text(11, .semibold)).foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Capsule().strokeBorder(Theme.line, lineWidth: 0.8))
                Text("Send").font(Theme.text(11, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 13).padding(.vertical, 5)
                    .background(Capsule().fill(DS.accentFill))
                    .overlay(Capsule().strokeBorder(DS.innerHighlight, lineWidth: 1))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.fill1))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.8))
    }

    private func fact(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.font(DS.Size.body, .medium)).foregroundStyle(Theme.ink)
                Text(detail).font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 2 · Brain

/// The exact call the settings on the left describe, written out. Every part of it — host, path,
/// model, and which body shape the provider style implies — comes from the live settings.
private struct BrainStage: View {
    @ObservedObject var settings: Settings
    var verified: Bool?

    private var responses: Bool { settings.apiStyle == "responses" }
    private var path: String { responses ? "/responses" : "/chat/completions" }
    private var host: String {
        let url = ProviderURL.endpoint(String(path.dropFirst()), base: settings.apiBaseURL)
        return url.host ?? "api.openai.com"
    }
    private var basePath: String {
        let url = ProviderURL.endpoint(String(path.dropFirst()), base: settings.apiBaseURL)
        return url.path.isEmpty ? path : url.path
    }
    private var model: String { settings.brainModel.isEmpty ? "model-id" : settings.brainModel }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            StageHeading(text: "What Avo will send", trailing: responses ? "Responses API" : "Chat Completions")
            StagePanel(padding: DS.Space.l) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: DS.Space.s) {
                        Text("POST").font(DS.mono(10, .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.accent.opacity(0.85)))
                        Text(host).font(DS.mono(11, .semibold)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    Text(basePath).font(DS.mono(11)).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle)
                    Rectangle().fill(Theme.line).frame(height: 1)
                    VStack(alignment: .leading, spacing: 4) {
                        codeLine("{")
                        codeLine("  \"model\": ", value: "\"\(model)\"", indent: true)
                        codeLine("  \"stream\": ", value: "true", indent: true)
                        codeLine(responses ? "  \"input\": " : "  \"messages\": ", value: "[ … ]", indent: true)
                        codeLine("}")
                    }
                }
            }
            HStack(spacing: DS.Space.s) {
                Image(systemName: "arrow.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ink4)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            .padding(.leading, DS.Space.l)
            StagePanel(padding: DS.Space.l, lit: verified == true) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: DS.Space.s) {
                        // Neutral until Test has actually run: a green 200 before anyone pressed
                        // anything would be claiming a result Avo does not have.
                        Text(verified == nil ? "RESPONSE" : (verified == true ? "200 OK" : "REJECTED"))
                            .font(DS.mono(10, .bold))
                            .foregroundStyle(verified == nil ? Theme.ink3 : (verified == true ? Theme.good : Theme.bad))
                        Spacer(minLength: 0)
                        if let verified {
                            HStack(spacing: 5) {
                                Image(systemName: verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text(verified ? "Key verified" : "Test failed").font(DS.font(DS.Size.caption, .semibold))
                            }
                            .foregroundStyle(verified ? Theme.good : Theme.bad)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                        } else {
                            Text("Press Test to check the key").font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3)
                        }
                    }
                    Rectangle().fill(Theme.line).frame(height: 1)
                    StageReply(text: "It's 4:12 PM.")
                }
            }
            Spacer(minLength: DS.Space.s)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                StageHeading(text: "Any of these work")
                ForEach(Self.alternatives, id: \.url) { alt in
                    HStack(spacing: DS.Space.s) {
                        Text(alt.name).font(DS.font(DS.Size.caption, .medium)).foregroundStyle(Theme.ink2)
                            .frame(width: 82, alignment: .leading)
                        Text(alt.url).font(DS.mono(11)).foregroundStyle(Theme.ink3)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                }
            }
            Spacer(minLength: DS.Space.s)
            HStack(alignment: .top, spacing: DS.Space.s) {
                Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink3)
                    .padding(.top, 2)
                Text("The key is stored in your Keychain and sent only to this host. Avo has no server of its own to relay it through.")
                    .font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Base URLs that are known to work, so "OpenAI-compatible" is a concrete claim rather than an
    /// abstract one. Avo never starts any of these — they are addresses, not actions.
    private static let alternatives: [(name: String, url: String)] = [
        ("Ollama", "http://localhost:11434/v1"),
        ("LM Studio", "http://localhost:1234/v1"),
        ("OpenRouter", "https://openrouter.ai/api/v1"),
        ("Groq", "https://api.groq.com/openai/v1"),
    ]

    private func codeLine(_ key: String, value: String? = nil, indent: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(key).font(DS.mono(11)).foregroundStyle(indent ? Theme.accent.opacity(0.9) : Theme.ink3)
            if let value {
                Text(value).font(DS.mono(11)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 3 · Access

/// The same four permissions the left pane grants, with the reason each is asked for. A tile lights
/// the moment the poll sees the grant, so the answer to a system prompt shows up here.
private struct AccessStage: View {
    @ObservedObject var permissions: PermissionsModel

    private static let reasons: [PermissionKind: String] = [
        .microphone: "Hears you while you hold the talk key. Nothing is recorded between holds.",
        .speechRecognition: "Turns your speech into text on this Mac.",
        .inputMonitoring: "Notices the talk key in whatever app you're in. Can wait.",
        .accessibility: "Reads the selected text and the app you're in. Can wait.",
    ]

    private var granted: Int { PermissionKind.upFront.filter { permissions.status[$0] == .granted }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            StageHeading(text: "Why each one", trailing: "\(granted) of 4 granted")
            // Two hand-built rows rather than a grid: the tiles have to share the stage's height
            // evenly, and a lazy grid sizes its rows to their content instead.
            VStack(spacing: DS.Space.m) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: DS.Space.m) {
                        ForEach(PermissionKind.upFront[(row * 2)..<(row * 2 + 2)], id: \.id) { kind in
                            tile(kind).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            StagePanel {
                HStack(alignment: .top, spacing: DS.Space.s) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ink3).padding(.top, 1)
                    Text("Everything else — Screen Recording, Reminders, Calendars, Location, Full Disk Access — is asked for the first time something actually needs it, never up front.")
                        .font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func tile(_ kind: PermissionKind) -> some View {
        let on = permissions.status[kind] == .granted
        return StagePanel(padding: DS.Space.l, lit: on) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: kind.icon).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(on ? Theme.accent : Theme.ink2)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(on ? Theme.accent.opacity(0.18) : Color.white.opacity(0.06)))
                    Spacer(minLength: 0)
                    Image(systemName: on ? "checkmark" : "minus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(on ? Theme.good : Theme.ink4)
                }
                Text(kind.title).font(DS.font(DS.Size.body, .semibold)).foregroundStyle(Theme.ink)
                Text(Self.reasons[kind] ?? kind.detail)
                    .font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .animation(Theme.springCard, value: on)
    }
}

// MARK: - 4 · Try it

/// The live notch, mirrored. Everything on this stage is the real model: the waveform follows the
/// microphone, the transcript is what the recognizer heard, the reply is what streamed back.
private struct TryItStage: View {
    @ObservedObject var settings: Settings
    @ObservedObject var notch: NotchModel

    private var idle: Bool {
        notch.transcript.isEmpty && notch.responseText.isEmpty && notch.errorText == nil
            && notch.phase != .listening && notch.phase != .thinking
    }

    private var headerTitle: String {
        switch notch.phase {
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        default: return idle ? "Waiting for you" : "Avo"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            StageHeading(text: "Live from the notch")
            NotchMock(panelWidth: 350) {
                VStack(alignment: .leading, spacing: 10) {
                    NotchMockHeader(phase: notch.phase, title: headerTitle, level: notch.audioLevel)
                    if idle {
                        HStack(spacing: DS.Space.s) {
                            KeyCap(text: settings.talkKeyLabel, symbol: settings.talkKey == "fn" ? "globe" : nil)
                            Text("hold to talk").font(Theme.text(12)).foregroundStyle(Theme.ink3)
                            Spacer(minLength: 0)
                        }
                    }
                    if !notch.transcript.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            if notch.phase == .listening { StageWave(level: notch.audioLevel) }
                            Text(notch.transcript)
                                .font(Theme.text(notch.phase == .listening ? 14 : 12,
                                                 notch.phase == .listening ? .regular : .regular))
                                .foregroundStyle(notch.phase == .listening ? Theme.ink : Theme.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    } else if notch.phase == .listening {
                        HStack(spacing: 10) {
                            StageWave(level: notch.audioLevel)
                            Text("…").font(Theme.text(14)).foregroundStyle(Theme.ink3)
                            Spacer(minLength: 0)
                        }
                    }
                    if !notch.responseText.isEmpty {
                        StageReply(text: notch.responseText)
                    } else if notch.phase == .thinking {
                        ThinkingLine()
                    }
                    if let err = notch.errorText {
                        Text(err).font(Theme.text(12)).foregroundStyle(Theme.bad)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
                .animation(Theme.springCard, value: notch.transcript)
                .animation(Theme.springCard, value: notch.responseText)
            }
            .frame(minHeight: 230)
            .padding(.bottom, DS.Space.l)
            Text("What happens while you hold")
                .font(DS.font(DS.Size.body, .semibold)).foregroundStyle(Theme.ink)
            Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, DS.Space.xs)
            VStack(alignment: .leading, spacing: DS.Space.m) {
                beat("1", "Recognised on this Mac", "The words appear as you speak them. No audio leaves the machine.")
                beat("2", "Sent on release", "Only the text — and a screenshot if the request is about your screen.")
                beat("3", "Answered in place", "The reply lands in the notch, and anything that acts asks first.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func beat(_ n: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Text(n).font(DS.mono(10, .bold)).foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.font(DS.Size.body, .medium)).foregroundStyle(Theme.ink)
                Text(detail).font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 5 · Extras

/// What each extra actually buys, and where it stands right now.
private struct ExtrasStage: View {
    @ObservedObject var settings: Settings
    @ObservedObject var preview: VoicePreview
    var googleEmail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            StageHeading(text: "What these turn on")
            tile(icon: "globe",
                 title: "Google",
                 state: googleEmail == nil ? "Off" : "Connected",
                 on: googleEmail != nil,
                 detail: "Gmail, Calendar and Drive through your own account. Avo opens a sign-in page in your browser and keeps only a refresh token in your Keychain — no copy of your mail leaves your Mac.",
                 examples: ["“What's on my calendar tomorrow?”",
                            "“Reply to Priya that Thursday works.”",
                            "“Find the budget sheet in my Drive.”"])
            tile(icon: "speaker.wave.2.fill",
                 title: "Spoken replies",
                 state: settings.speakReplies ? "On" : "Off",
                 on: settings.speakReplies,
                 detail: "Reads the one-line reply aloud after each request, so you can keep your eyes where they are. Off by default; the system voice is used unless you add a Gemini key in Settings → Keys.",
                 examples: ["Preview plays the current voice.",
                            "Only the one-line reply is read — never a whole card.",
                            "Turning it off stops mid-sentence."])
            HStack(alignment: .top, spacing: DS.Space.s) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.ink3).padding(.top, 2)
                Text("Neither is needed to use Avo, and both can be turned on or off later in Settings.")
                    .font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func tile(icon: String, title: String, state: String, on: Bool, detail: String, examples: [String]) -> some View {
        StagePanel(padding: DS.Space.l, lit: on) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(on ? Theme.accent : Theme.ink2)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(on ? Theme.accent.opacity(0.18) : Color.white.opacity(0.06)))
                    Text(title).font(DS.font(DS.Size.body, .semibold)).foregroundStyle(Theme.ink)
                    Spacer(minLength: DS.Space.s)
                    StatusLabel(state: on ? .ok : .off, text: state)
                }
                Text(detail).font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(examples, id: \.self) { e in
                    Text(e).font(DS.font(DS.Size.caption, .medium)).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, DS.Space.s).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25)))
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity)
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
        VStack(alignment: .leading, spacing: DS.Space.l) {
            StageHeading(text: "Try one")
            Spacer(minLength: 0)
            AvoMark(size: 120, animated: true)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.l)
            Spacer(minLength: 0)
            VStack(spacing: DS.Space.s) {
                ForEach(Self.examples, id: \.self) { e in
                    ExamplePill(text: e) { run(e) }
                }
            }
            Text("Runs the request exactly as a held key would — the reply appears in the notch.")
                .font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

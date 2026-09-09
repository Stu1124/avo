import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - General

struct GeneralPage: View {
    @ObservedObject var s: Settings
    @State private var launchAtLogin = false
    @State private var loginError: String? = nil
    @State private var detecting = false
    @State private var detectMessage: String? = nil
    @State private var reminderLists: [(id: String, label: String)] = []

    private static let efforts: [(id: String, label: String)] = [
        (id: "none", label: "None"), (id: "low", label: "Low"), (id: "medium", label: "Medium"),
        (id: "high", label: "High"), (id: "max", label: "Max"),
    ]
    static let styleOptions: [(id: String, label: String)] = [(id: "responses", label: "OpenAI"), (id: "chat", label: "OpenAI-compatible")]

    /// Anything that is not the Responses style reads as "OpenAI-compatible" in the picker.
    private var styleBinding: Binding<String> {
        Binding(get: { s.apiStyle == "responses" ? "responses" : "chat" }, set: { s.apiStyle = $0 })
    }

    private var launchBinding: Binding<Bool> {
        Binding(get: { launchAtLogin }, set: { on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchAtLogin = on; loginError = nil
            } catch {
                loginError = error.localizedDescription
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            PageHeader(title: "General", subtitle: "How Avo listens, sees and thinks.")
            SectionCard(title: "Keys") {
                PickerRow(title: "Hold to talk", subtitle: "Release to send. A silent modifier tap cancels quietly; fn/F-key taps open the composer. Esc cancels. ⌃⌥ always works as an alias.", selection: $s.talkKey,
                          options: [(id: "fn", label: "fn / 🌐"), (id: "rightCommand", label: "Right ⌘"), (id: "rightOption", label: "Right ⌥"), (id: "rightControl", label: "Right ⌃"), (id: "controlOption", label: "⌃ ⌥"), (id: "f5", label: "F5"), (id: "f6", label: "F6")])
                PickerRow(title: "Open composer", subtitle: "Global shortcut to type to Avo. Clicking the notch also opens it.", selection: $s.composerShortcut,
                          options: [(id: "optionSpace", label: "⌥ Space"), (id: "commandShiftSpace", label: "⌘ ⇧ Space"), (id: "controlSpace", label: "⌃ Space"), (id: "fnSpace", label: "fn Space"), (id: "none", label: "Off")])
            }
            SectionCard(title: "Context", footer: "Text you highlight is attached whenever it exists and shows as a chip in the notch. Copied text stays out.") {
                ToggleRow(title: "Screen awareness", subtitle: "Lets Avo capture your screen and bring it into the notch.", isOn: $s.screenAwareness)
                ToggleRow(title: "Always attach the screen", subtitle: "Off: the screen is captured only when you refer to it (\"this\", \"here\", \"on my screen\"); Avo can still take a look on its own when it needs one. On: every request, which costs about 1K tokens each.", isOn: $s.alwaysScreenshot)
                    .disabled(!s.screenAwareness)
                ToggleRow(title: "Screenshot animation", subtitle: "Watch the capture fly into the notch. Turn off for a silent capture.", isOn: $s.animateScreenshots)
                    .disabled(!s.screenAwareness)
                ToggleRow(title: "Ask before actions", subtitle: "Shows an editable card before anything is sent, created or deleted.", isOn: $s.confirmActions)
                ToggleRow(title: "Sounds", subtitle: "Soft cues when listening starts, cards appear and work finishes.", isOn: $s.soundsEnabled)
            }
            SectionCard(title: "Persona", footer: "Context files are read on every request and sent whole, so keep them short.") {
                TextRow(title: "Your name", subtitle: "What Avo calls you. Leave it empty and Avo says \"the user\".", placeholder: "Optional", text: $s.userName, width: 200)
                MultilineTextRow(title: "Writing style", subtitle: "Applied whenever Avo drafts a message, email or reply for you.", text: $s.writingStyle)
                ActionRow(title: "Context files", subtitle: "Notes or rules Avo should always have on hand.") {
                    DSPill("Add file…", icon: "plus") { addContextFiles() }
                }
                for path in s.contextFiles {
                    ActionRow(title: (path as NSString).lastPathComponent, subtitle: Self.shortPath(path)) {
                        DSPill("Remove", style: .destructive) { s.contextFiles.removeAll { $0 == path } }
                    }
                }
            }
            SectionCard(title: "Model") {
                PickerRow(title: "Provider style", subtitle: "OpenAI uses the Responses API. OpenAI-compatible works with Ollama, LM Studio, OpenRouter, Groq and xAI.", selection: styleBinding,
                          options: Self.styleOptions)
                TextRow(title: "Base URL", placeholder: "https://api.openai.com/v1", text: $s.apiBaseURL, width: 280)
                KeyField(provider: .openAI)
                TextRow(title: "Model", subtitle: "Any model id the server accepts.", placeholder: "model id", text: $s.brainModel, width: 220)
                ActionRow(title: "Detect local", subtitle: detectMessage ?? "Looks for an Ollama server already running on this Mac.") {
                    DSPill("Detect", busy: detecting) { detectOllama() }
                }
                PickerRow(title: "Effort", subtitle: "Reasoning budget for everyday requests (OpenAI models).", selection: $s.brainEffort, options: Self.efforts)
                ToggleRow(title: "Deep mode", subtitle: "Slower and more thorough. Uses the deep effort below.", isOn: $s.deepMode)
                PickerRow(title: "Deep effort", selection: $s.deepEffort, options: Self.efforts)
            }
            SectionCard(title: "Defaults", footer: loginError) {
                // A picker once Reminders access exists; the free-text field is the fallback, so the
                // row still works before the just-in-time prompt has ever been answered.
                if reminderLists.isEmpty {
                    TextRow(title: "Default reminder list", subtitle: "Where new reminders go unless you name a list. Empty uses the list Reminders itself defaults to; grant Reminders to pick from your lists.", placeholder: "Default list", text: $s.defaultReminderList, width: 160)
                } else {
                    PickerRow(title: "Default reminder list", subtitle: "Where new reminders go unless you name a list. \"Default list\" uses the list Reminders itself defaults to.",
                              selection: $s.defaultReminderList, options: [(id: "", label: "Default list")] + reminderLists)
                }
                ToggleRow(title: "Launch at login", subtitle: "Start Avo quietly in the menu bar when you sign in.", isOn: launchBinding)
            }
            DataSection(s: s)
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            RemindersStore.shared.warmIfAuthorized()
            // The stored list may have been renamed or deleted; keep it selectable either way.
            var names = RemindersStore.shared.cachedListNames
            if !names.isEmpty, !names.contains(s.defaultReminderList), !s.defaultReminderList.isEmpty {
                names.append(s.defaultReminderList)
            }
            reminderLists = names.map { (id: $0, label: $0) }
        }
    }

    /// Home-relative form of a path, so long paths stay readable in the row.
    static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func addContextFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Pick text or markdown files Avo should always read."
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.map(\.path).filter { !s.contextFiles.contains($0) }
        if !added.isEmpty { s.contextFiles += added }
    }

    /// Read-only probe of a running Ollama server. Never starts, installs or pulls anything.
    private func detectOllama() {
        detecting = true
        Task {
            let found = await OllamaDetect.models()
            if let found, !found.isEmpty {
                s.apiBaseURL = OllamaDetect.defaultBase
                s.apiStyle = "chat"
                s.brainModel = found[0]
                detectMessage = "Ollama found: \(found.prefix(4).joined(separator: ", "))"
            } else if found != nil {
                detectMessage = "Ollama is running but has no models. Try: ollama pull llama3.2"
            } else {
                detectMessage = "No Ollama at localhost:11434."
            }
            detecting = false
        }
    }
}

// MARK: - Data

/// What Avo keeps and for how long. Both stores grow with use, so both get a limit and a button.
struct DataSection: View {
    @ObservedObject var s: Settings
    @ObservedObject private var history = History.shared
    @State private var usage: (count: Int, bytes: Int64) = (0, 0)
    @State private var message: String?
    @State private var confirmClear = false

    /// "Keep forever" first, because it is the default: nothing is deleted until a limit is picked.
    private static let retentions: [(id: String, label: String)] = [
        (id: "0", label: "Keep forever"), (id: "7", label: "7 days"), (id: "14", label: "14 days"),
        (id: "30", label: "30 days"), (id: "90", label: "90 days"),
    ]

    private func binding(_ keyPath: ReferenceWritableKeyPath<Settings, Int>) -> Binding<String> {
        Binding(get: { String(s[keyPath: keyPath]) }, set: { s[keyPath: keyPath] = Int($0) ?? 0 })
    }

    var body: some View {
        SectionCard(title: "Data", footer: message ?? "Screenshots live in \(GeneralPage.shortPath(Paths.screenshotsDir.path)). History is a single JSON file next to it. Both are kept forever unless you pick a limit; a limit is applied at launch.") {
            PickerRow(title: "Keep screenshots for",
                      subtitle: usage.count == 0 ? "Every screen-aware request saves one." : "\(usage.count) file\(usage.count == 1 ? "" : "s") · \(Retention.formatBytes(usage.bytes)).",
                      selection: binding(\.screenshotRetentionDays), options: Self.retentions)
            ActionRow(title: "Purge screenshots now", subtitle: "Deletes the ones already past that age.") {
                DSPill("Purge now", icon: "trash") {
                    let n = Retention.purgeScreenshots(olderThan: s.screenshotRetentionDays)
                    usage = Retention.screenshotUsage()
                    message = n == 0 ? "Nothing was old enough to delete." : "Deleted \(n) screenshot\(n == 1 ? "" : "s")."
                }
            }
            PickerRow(title: "Keep history for",
                      subtitle: "\(history.entries.count) turn\(history.entries.count == 1 ? "" : "s") and \(history.summaries.count) summar\(history.summaries.count == 1 ? "y" : "ies") stored.",
                      selection: binding(\.historyRetentionDays), options: Self.retentions)
            ActionRow(title: "Clear history", subtitle: confirmClear ? "This deletes every turn and summary. It can't be undone." : "Deletes every turn and summary, now.") {
                if confirmClear {
                    DSPill("Cancel", style: .ghost) { withAnimation(Theme.springQuick) { confirmClear = false } }
                    DSPill("Clear everything", style: .destructive) {
                        history.clear()
                        withAnimation(Theme.springQuick) { confirmClear = false }
                        message = "History cleared."
                    }
                } else {
                    DSPill("Clear…", icon: "trash", style: .destructive) {
                        withAnimation(Theme.springQuick) { confirmClear = true }
                    }
                    .disabled(history.entries.isEmpty && history.summaries.isEmpty)
                    .opacity(history.entries.isEmpty && history.summaries.isEmpty ? 0.5 : 1)
                }
            }
        }
        .onAppear { usage = Retention.screenshotUsage() }
    }
}

// MARK: - Voice

struct VoicePage: View {
    @ObservedObject var s: Settings
    @ObservedObject var preview: VoicePreview

    private static let ttsModels = ["gemini-3.1-flash-tts-preview", "gemini-2.5-flash-preview-tts"]
    private static let realtimeModels = ["gpt-realtime-2.1", "gpt-realtime-2.1-mini"]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            PageHeader(title: "Voice", subtitle: "Spoken replies and hands-free voice mode.")
            SectionCard(title: "Dictation", footer: "Recognition stays on this Mac. Add names and specialist terms separated by commas.") {
                PickerRow(title: "Microphone", subtitle: "Defaults to the Mac microphone. This does not change where music and replies play.", selection: $s.microphoneUID,
                          options: AudioInputDevice.pickerOptions)
                PickerRow(title: "Recognition profile", subtitle: "Tune the recognizer for how you speak and where the microphone is.", selection: $s.dictationProfile,
                          options: [(id: "standard", label: "Standard"), (id: "farField", label: "Far from microphone"), (id: "speechVariation", label: "Accent or speech variation")])
                TextRow(title: "Custom vocabulary", subtitle: "Bias recognition toward names, products and technical terms.", placeholder: "Avo, Claude, Codex…", text: $s.dictationVocabulary, width: 320)
            }
            SectionCard(title: "Spoken replies") {
                ToggleRow(title: "Speak replies", subtitle: "Read the one-line reply aloud after each request.", isOn: $s.speakReplies)
                PickerRow(title: "Engine", subtitle: "Apple runs on this Mac with no key. Gemini needs a key in Settings → Keys.", selection: $s.ttsEngine,
                          options: [(id: "apple", label: "Apple (on-device)"), (id: "gemini", label: "Gemini")])
                if s.ttsEngine == "gemini" {
                    PickerRow(title: "TTS model", selection: $s.ttsModel, options: Self.ttsModels)
                    ActionRow(title: "Voice", subtitle: preview.message ?? "Gemini prebuilt voices.") {
                        DSMenu(selection: $s.ttsVoice, options: GeminiVoices.all.map { (id: $0, label: $0) })
                        previewPill
                    }
                    TextRow(title: "Style", subtitle: "How the voice should sound. Prepended to every line.", placeholder: "calm, composed…", text: $s.ttsStyle, width: 260)
                } else {
                    // The preview belongs on both engines; hiding it under Gemini left the "switch the
                    // engine" hint on a row nobody could reach while Apple was selected.
                    ActionRow(title: "Voice", subtitle: preview.message ?? "The system voice, spoken on this Mac.") {
                        previewPill
                    }
                }
            }
            SectionCard(title: "Voice mode", footer: "Voice mode keeps the microphone open for a back-and-forth conversation until you end it.") {
                PickerRow(title: "Realtime model", selection: $s.realtimeModel, options: Self.realtimeModels)
                ActionRow(title: "Start voice mode", subtitle: "Also available from the menu bar.") {
                    DSPill("Start voice mode", icon: "waveform", style: .primary) { VoiceModeSession.shared.toggle() }
                }
            }
            HandsFreeSection()
        }
    }

    private var previewPill: some View {
        DSPill(preview.playing ? "Playing" : "Preview", icon: preview.playing ? nil : "play.fill", busy: preview.playing) {
            preview.play()
        }
    }
}

// MARK: - Apps

@MainActor
final class ToolGroupsModel: ObservableObject {
    struct GroupInfo: Identifiable {
        let name: String
        let icon: String
        let tools: [Tool]
        var id: String { name }
    }

    static let known: [(name: String, icon: String)] = [
        ("iMessage", "app:com.apple.MobileSMS"), ("Reminders", "app:com.apple.reminders"), ("Finder", "app:com.apple.finder"),
        ("Apps", "app.dashed"), ("Spotify", "app:com.spotify.client"), ("Gmail", "envelope.fill"), ("Calendar", "calendar"),
        ("Drive", "externaldrive.fill"), ("Coding", "sparkles"), ("Text", "text.cursor"), ("Memory", "brain"), ("Notes", "app:com.apple.Notes"), ("Scheduling", "clock.badge"), ("MCP", "puzzlepiece.extension"),
    ]

    @Published private(set) var disabled: Set<String>
    @Published private(set) var groups: [GroupInfo] = []

    init() {
        disabled = Set(UserDefaults.standard.stringArray(forKey: "disabledToolGroups") ?? [])
        reload()
    }

    func reload() {
        let byGroup = Dictionary(grouping: ToolRegistry.shared.all) { $0.group }
        var ordered: [GroupInfo] = []
        for k in Self.known where byGroup[k.name] != nil {
            ordered.append(GroupInfo(name: k.name, icon: k.icon, tools: byGroup[k.name]!))
        }
        let knownNames = Set(Self.known.map(\.name))
        for name in byGroup.keys.filter({ !knownNames.contains($0) }).sorted() {
            ordered.append(GroupInfo(name: name, icon: "puzzlepiece.extension.fill", tools: byGroup[name]!))
        }
        groups = ordered
    }

    func isEnabled(_ group: String) -> Bool { !disabled.contains(group) }

    func set(_ group: String, enabled: Bool) {
        if enabled { disabled.remove(group) } else { disabled.insert(group) }
        UserDefaults.standard.set(Array(disabled).sorted(), forKey: "disabledToolGroups")
    }

    func binding(_ group: String) -> Binding<Bool> {
        Binding(get: { [weak self] in self?.isEnabled(group) ?? true },
                set: { [weak self] on in self?.set(group, enabled: on) })
    }
}

struct AppsPage: View {
    @ObservedObject var model: ToolGroupsModel
    @StateObject private var mcp = MCPServersModel()
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            PageHeader(title: "Apps", subtitle: "What Avo can reach. Off means the model never sees those tools.")
            MCPServersSection(model: mcp)
            if model.groups.isEmpty {
                EmptyState(icon: "square.grid.2x2", text: "No tools registered yet. They arrive a moment after launch.")
            }
            ForEach(model.groups) { g in
                let open = expanded.contains(g.name)
                SectionCard {
                    GroupHeaderRow(group: g, enabled: model.binding(g.name), expanded: open) {
                        withAnimation(Theme.springQuick) {
                            if open { expanded.remove(g.name) } else { expanded.insert(g.name) }
                        }
                    }
                    if open {
                        g.tools.map { AnyView(ToolRow(tool: $0)) }
                    }
                }
            }
        }
        .onAppear { model.reload() }
    }
}

private struct GroupHeaderRow: View {
    let group: ToolGroupsModel.GroupInfo
    @Binding var enabled: Bool
    var expanded: Bool
    var toggleExpanded: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.m) {
            GroupIcon(icon: group.icon, size: 28)
            Button(action: toggleExpanded) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name).font(DS.font(DS.Size.body, .semibold)).foregroundStyle(enabled ? Theme.ink : Theme.ink3)
                        Text("\(group.tools.count) \(group.tools.count == 1 ? "tool" : "tools")").font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ink4)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("", isOn: $enabled).labelsHidden().toggleStyle(DSToggleStyle())
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }
}

private struct ToolRow: View {
    let tool: Tool
    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: tool.statusIcon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink3)
                .frame(width: 28).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name).font(DS.mono(DS.Size.caption)).foregroundStyle(Theme.ink)
                Text(tool.description.firstSentence).font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if tool.confirmation != nil {
                Text("asks first").font(DS.font(DS.Size.label, .semibold)).foregroundStyle(Theme.ink2)
                    .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
                    .background(Capsule().fill(Theme.fill2))
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .transition(.opacity)
    }
}

// MARK: - Google

struct GooglePage: View {
    @State private var connected = false
    @State private var email: String? = nil
    @State private var busy = false
    @State private var error: String? = nil
    @State private var hasCredentials = false
    @State private var credentialsMessage: String? = nil

    private var scopeNames: [String] {
        GoogleAuth.scopes.map { $0.replacingOccurrences(of: "https://www.googleapis.com/auth/", with: "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            PageHeader(title: "Google", subtitle: "Gmail, Calendar and Drive through your own account.")
            SectionCard(title: "Account", footer: error) {
                ActionRow(title: connected ? (email ?? "Connected") : "Not connected",
                          subtitle: connected ? "Avo can read and act in Gmail, Calendar and Drive." : "Sign in with Google in your browser. Nothing is stored except a refresh token in your Keychain.",
                          icon: "globe") {
                    StatusLabel(state: connected ? .ok : .off, text: connected ? "Connected" : "Off")
                    if connected {
                        DSPill("Disconnect", style: .destructive) {
                            GoogleAuth.shared.signOut(); refresh()
                        }
                    } else {
                        DSPill("Connect", icon: "arrow.up.forward", style: .primary, busy: busy) { connect() }
                    }
                }
            }
            SectionCard(title: "Credentials", footer: credentialsMessage ?? "Create an OAuth client (Desktop app) in the Google Cloud console, download its JSON, and pick it here. Avo copies it into its own folder.") {
                ActionRow(title: "OAuth client", subtitle: hasCredentials ? "Loaded from the credentials file." : "Not set. Sign-in needs a client id and secret.") {
                    StatusLabel(state: hasCredentials ? .ok : .off, text: hasCredentials ? "Set" : "Missing")
                    DSPill("Choose credentials JSON…") { chooseCredentials() }
                }
            }
            SectionCard(title: "Scopes", footer: "Requested once at sign-in. Revoke any time at myaccount.google.com → Security → Third-party access.") {
                ActionRow(title: "What Avo asks for", subtitle: scopeNames.joined(separator: " · ")) { EmptyView() }
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        connected = GoogleAuth.shared.isConnected
        email = GoogleAuth.shared.email
        hasCredentials = (Settings.shared.googleClientId ?? "").isEmpty == false
    }

    /// Copies a downloaded OAuth client JSON into Avo's folder and re-reads the client from it.
    private func chooseCredentials() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.message = "Pick the OAuth client JSON you downloaded from the Google Cloud console."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let fm = FileManager.default
        // Stage next to the destination and swap, rather than deleting first: a failed copy would
        // otherwise leave the user with no credentials file at all.
        let staged = Paths.googleOAuthFile.deletingLastPathComponent()
            .appendingPathComponent("google-oauth-\(UUID().uuidString).tmp")
        do {
            try fm.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: staged)
            if fm.fileExists(atPath: Paths.googleOAuthFile.path) {
                _ = try fm.replaceItemAt(Paths.googleOAuthFile, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: Paths.googleOAuthFile)
            }
        } catch {
            try? fm.removeItem(at: staged)
            credentialsMessage = error.localizedDescription
            return
        }
        if Settings.importGoogleOAuthClient(force: true) {
            credentialsMessage = "Client imported. Connect above."
            Sounds.shared.play(.done)
        } else {
            credentialsMessage = "That file has no client_id and client_secret."
            Sounds.shared.play(.error)
        }
        refresh()
    }

    private func connect() {
        busy = true; error = nil
        Task {
            do {
                let e = try await GoogleAuth.shared.signIn()
                email = e; connected = true
                Sounds.shared.play(.done)
            } catch {
                self.error = error.localizedDescription
                Sounds.shared.play(.error)
            }
            busy = false
        }
    }
}

// MARK: - Coding

struct CodingPage: View {
    @ObservedObject var s: Settings
    @State private var paths: [String: String] = [:]
    @State private var detecting = true

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            PageHeader(title: "Coding", subtitle: "Hand work to Claude Code or Codex from your voice.")
            SectionCard(title: "Agent", footer: s.codingAutoApprove ? "With auto-approve on, the agent changes files and runs commands without stopping to ask. Reserve it for projects you could recover if something goes wrong." : nil) {
                PickerRow(title: "Default agent", subtitle: "Used unless you name one.", selection: $s.codingDefaultAgent,
                          options: [(id: "claude", label: "Claude Code"), (id: "codex", label: "Codex")])
                ToggleRow(title: "Auto-approve", subtitle: "Skip permission prompts inside the coding agent.", isOn: $s.codingAutoApprove)
            }
            SectionCard(title: "Detected CLIs", footer: "Looked up with your login shell (/bin/zsh -lc). Install with npm to add a missing one.") {
                cliRow("Claude Code", cmd: "claude")
                cliRow("Codex", cmd: "codex")
            }
        }
        .onAppear { detect() }
    }

    private func cliRow(_ title: String, cmd: String) -> some View {
        let p = paths[cmd] ?? ""
        return ActionRow(title: title, subtitle: p.isEmpty ? (detecting ? "Looking…" : "Not found in PATH") : p) {
            StatusLabel(state: p.isEmpty ? (detecting ? .off : .bad) : .ok, text: p.isEmpty ? (detecting ? "…" : "Missing") : "Found")
        }
    }

    private func detect() {
        detecting = true
        Task {
            let found = await Self.detectCLIs()
            paths = found; detecting = false
        }
    }

    static func detectCLIs() async -> [String: String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var out: [String: String] = [:]
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", "for c in claude codex; do printf '%s=%s\\n' \"$c\" \"$(command -v $c)\"; done"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do {
                    try p.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                        if parts.count == 2, !parts[1].isEmpty { out[parts[0]] = parts[1] }
                    }
                } catch {
                    Log.warn("CLI detection failed: \(error.localizedDescription)")
                }
                cont.resume(returning: out)
            }
        }
    }
}

// MARK: - Keys

struct KeysPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            PageHeader(title: "Keys", subtitle: "Stored in the macOS Keychain. Test sends one authenticated request.")
            SectionCard(title: "Providers", footer: "The brain's API key lives in Settings → General → Model.") {
                KeyField(provider: .gemini)
                KeyField(provider: .fish)
                KeyField(provider: .xai)
            }
        }
    }
}

// MARK: - Permissions

struct PermissionsPage: View {
    @ObservedObject var model: PermissionsModel
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            PageHeader(title: "Permissions", subtitle: "Status updates live. Request shows the system prompt where macOS offers one.")
            SectionCard(title: "Required to talk", footer: "Onboarding asks for these four. Avo cannot hear you without them.") {
                PermissionKind.upFront.map { AnyView(PermissionRow(kind: $0, model: model)) }
            }
            SectionCard(title: "Asked when a tool needs one", footer: "Avo requests each of these the first time something actually needs it. Grant them early here if you would rather not be interrupted. Full Disk Access has no in-app prompt: open Settings and add Avo to the list.") {
                PermissionKind.allCases.filter { !$0.essential }.map { AnyView(PermissionRow(kind: $0, model: model)) }
            }
        }
        .onAppear { model.start(interval: 2) }
        .onDisappear { model.stop() }
    }
}

// MARK: - About

struct AboutPage: View {
    @ObservedObject var s: Settings
    @State private var exporting = false
    @State private var diagnosticsMessage: String?
    @State private var redactSpokenText = true

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }
    /// The Mac this is running on. The old line claimed "macOS 26" for every install; the floor is 15.
    private var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)"
    }
    private var logURL: URL { Paths.appSupport.appendingPathComponent("avo.log") }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            PageHeader(title: "About")
            HStack(spacing: DS.Space.m) {
                AvoMark(size: 56)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Avo").font(DS.font(DS.Size.lead, .semibold)).foregroundStyle(Theme.ink)
                    Text("Version \(version) · \(systemVersion)").font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3)
                }
            }
            SectionCard(title: "Files") {
                ActionRow(title: "Memory", subtitle: GeneralPage.shortPath(Paths.memoryFile.path)) {
                    DSPill("Open", icon: "doc.text") { NSWorkspace.shared.open(Paths.memoryFile) }
                    DSPill("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([Paths.memoryFile]) }
                }
                ActionRow(title: "Log", subtitle: GeneralPage.shortPath(logURL.path)) {
                    DSPill("Open", icon: "doc.plaintext") { NSWorkspace.shared.open(logURL) }
                }
                ActionRow(title: "History", subtitle: GeneralPage.shortPath(Paths.historyDB.path)) {
                    DSPill("Show history", icon: "clock.arrow.circlepath") { HistoryWindow.shared.show() }
                }
            }
            SectionCard(title: "Setup", footer: diagnosticsMessage) {
                ActionRow(title: "Reset onboarding", subtitle: "Runs the first-run flow again on next launch, or now.") {
                    DSPill("Reset", style: .destructive) {
                        s.onboarded = false
                        OnboardingWindow.shared.show()
                    }
                }
                ToggleRow(title: "Redact spoken text",
                          subtitle: "Replaces what you said, and what Avo passed to each tool, with [redacted] in the exported log. Off: your requests are included as you said them.",
                          isOn: $redactSpokenText)
                ActionRow(title: "Export diagnostics", subtitle: "Zips your log and settings to the Desktop for a bug report. No keys or tokens. macOS asks for Desktop access the first time.") {
                    DSPill("Export", icon: "square.and.arrow.up", busy: exporting) { exportDiagnostics() }
                }
            }
        }
    }

    private func exportDiagnostics() {
        exporting = true
        diagnosticsMessage = nil
        do {
            let url = try Diagnostics.export(redactSpokenText: redactSpokenText)
            diagnosticsMessage = "Saved \(url.lastPathComponent) to your Desktop."
            NSWorkspace.shared.activateFileViewerSelecting([url])
            Sounds.shared.play(.done)
        } catch {
            diagnosticsMessage = error.localizedDescription
            Sounds.shared.play(.error)
        }
        exporting = false
    }
}

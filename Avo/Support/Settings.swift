import Foundation
import Combine

/// User settings. Non-secret values in UserDefaults, secrets in Keychain.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    // Models
    @Published var brainModel = "gpt-5.6-luna" { didSet { save("brainModel", brainModel) } }
    /// Reasoning effort for everyday requests. "none" skips the reasoning pass entirely.
    @Published var brainEffort = "none" { didSet { save("brainEffort", brainEffort) } }
    @Published var deepEffort = "max" { didSet { save("deepEffort", deepEffort) } }
    @Published var realtimeModel = "gpt-realtime-2.1" { didSet { save("realtimeModel", realtimeModel) } }
    @Published var ttsModel = "gemini-3.1-flash-tts-preview" { didSet { save("ttsModel", ttsModel) } }
    @Published var ttsVoice = "Charon" { didSet { save("ttsVoice", ttsVoice) } }
    @Published var ttsStyle = "calm, composed, quietly confident, like a discreet British butler" { didSet { save("ttsStyle", ttsStyle) } }

    // Provider
    /// Base URL of an OpenAI-compatible API. Responses style needs OpenAI; chat style works with Ollama, LM Studio, OpenRouter, Groq, xAI, and Anthropic's compat endpoint.
    @Published var apiBaseURL = "https://api.openai.com/v1" { didSet { save("apiBaseURL", apiBaseURL) } }
    /// "responses" (OpenAI Responses API), "chat" (chat completions), "foundation" (Apple on-device, macOS 26).
    @Published var apiStyle = "responses" { didSet { save("apiStyle", apiStyle) } }
    /// Spoken replies: "apple" (on-device, no key) or "gemini".
    @Published var ttsEngine = "apple" { didSet { save("ttsEngine", ttsEngine) } }

    // Persona
    @Published var userName = "" { didSet { save("userName", userName) } }
    @Published var writingStyle = Settings.defaultWritingStyle { didSet { save("writingStyle", writingStyle) } }
    /// Absolute paths of files whose contents are appended to the system prompt.
    @Published var contextFiles: [String] = [] { didSet { save("contextFiles", contextFiles) } }

    static let defaultWritingStyle = """
    Plain words, short sentences, one idea per sentence. No filler, no stacked thanks, no corporate phrases. \
    Texts to friends: short and casual. Emails: open "Hi Name," make the ask, close with the user's name.
    """

    var isOpenAIHost: Bool { URL(string: apiBaseURL)?.host == "api.openai.com" }

    // Behaviour
    @Published var speakReplies = false { didSet { save("speakReplies", speakReplies) } }
    @Published var soundsEnabled = true { didSet { save("soundsEnabled", soundsEnabled) } }
    @Published var animateScreenshots = true { didSet { save("animateScreenshots", animateScreenshots) } }
    @Published var screenAwareness = true { didSet { save("screenAwareness", screenAwareness) } }
    /// Off: the screen is captured only when the request refers to it. On: every request, as before.
    @Published var alwaysScreenshot = false { didSet { save("alwaysScreenshot", alwaysScreenshot) } }
    @Published var confirmActions = true { didSet { save("confirmActions", confirmActions) } }
    @Published var deepMode = false { didSet { save("deepMode", deepMode) } }
    /// Empty means "whatever Reminders itself treats as the default list", which is the default.
    @Published var defaultReminderList = "" { didSet { save("defaultReminderList", defaultReminderList) } }
    /// Days of screenshots to keep on disk. 0 keeps them forever, and is the default: an install
    /// that has been running for months must not lose anything the first time this build starts.
    @Published var screenshotRetentionDays = 0 { didSet { save("screenshotRetentionDays", screenshotRetentionDays) } }
    /// Days of conversation history to keep. 0 keeps everything, and is the default for the same reason.
    @Published var historyRetentionDays = 0 { didSet { save("historyRetentionDays", historyRetentionDays) } }
    @Published var onboarded = false { didSet { save("onboarded", onboarded) } }
    @Published var codingDefaultAgent = "claude" { didSet { save("codingDefaultAgent", codingDefaultAgent) } }
    @Published var codingAutoApprove = false { didSet { save("codingAutoApprove", codingAutoApprove) } }
    /// Push-to-talk key: fn, rightCommand, rightOption, rightControl, controlOption, f5, f6.
    @Published var talkKey = "fn" { didSet { save("talkKey", talkKey); HotkeyMonitor.shared.talkKey = talkKey } }
    /// Global shortcut that opens the composer: none, optionSpace, commandShiftSpace, controlSpace, fnSpace.
    @Published var composerShortcut = "optionSpace" { didSet { save("composerShortcut", composerShortcut); HotkeyMonitor.shared.composerShortcut = composerShortcut } }
    /// Hands-free wake word ("Hey Avo"): keeps an on-device listener running. Toggling starts/stops it live.
    @Published var handsFree = false {
        didSet {
            save("handsFree", handsFree)
            // Hands-free needs SpeechAnalyzer; on macOS 15 the setting is hidden and this is a no-op.
            if #available(macOS 26, *) {
                if handsFree { WakeWord.shared.start() } else { WakeWord.shared.stop() }
            }
        }
    }
    @Published var wakeWord = "Hey Avo" { didSet { save("wakeWord", wakeWord) } }
    /// Tunes Apple's on-device dictation model for the user's microphone/speech characteristics.
    @Published var dictationProfile = "standard" { didSet { save("dictationProfile", dictationProfile) } }
    /// Avo-only input device. Defaults to the Mac's built-in microphone; output routing is unaffected.
    @Published var microphoneUID = AudioInputDevice.builtInChoiceID {
        didSet {
            guard microphoneUID != oldValue else { return }
            save("microphoneUID", microphoneUID)
            Transcriber.shared.microphoneSelectionDidChange()
            if #available(macOS 26, *) { WakeWord.shared.microphoneSelectionDidChange() }
        }
    }
    /// Comma-separated product names, people, and specialist terms that speech recognition should favor.
    @Published var dictationVocabulary = "Avo, Claude, Codex, ChatGPT, OpenAI, SwiftUI, Xcode, iMessage, Gmail" { didSet { save("dictationVocabulary", dictationVocabulary) } }

    /// Modifier-only talk keys are too easy to tap accidentally while using normal shortcuts.
    /// Keep tap-to-type on dedicated keys; a silent modifier tap should simply disappear.
    var shortTapOpensComposer: Bool {
        talkKey == "fn" || talkKey == "f5" || talkKey == "f6"
    }

    var dictationTerms: [String] {
        dictationVocabulary
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(100)
            .map { $0 }
    }

#if DEBUG
    /// Screenshot harness only: the talk key to *display* without touching the stored setting.
    nonisolated(unsafe) static var previewTalkKeyOverride: String?
#endif

    /// The talk key the UI should name. Equal to `talkKey` outside the DEBUG screenshot harness.
    var displayTalkKey: String {
#if DEBUG
        if let o = Settings.previewTalkKeyOverride { return o }
#endif
        return talkKey
    }

    var talkKeyLabel: String {
        switch displayTalkKey {
        case "rightCommand": return "Right ⌘"
        case "rightOption": return "Right ⌥"
        case "rightControl": return "Right ⌃"
        case "controlOption": return "⌃ ⌥"
        case "f5": return "F5"
        case "f6": return "F6"
        default: return "fn"
        }
    }

    var composerShortcutLabel: String {
        switch composerShortcut {
        case "commandShiftSpace": return "⌘ ⇧ Space"
        case "controlSpace": return "⌃ Space"
        case "fnSpace": return "fn Space"
        case "none": return "menu bar"
        default: return "⌥ Space"
        }
    }

    private init() {
        brainModel = d.string(forKey: "brainModel") ?? brainModel
        brainEffort = d.string(forKey: "brainEffort") ?? brainEffort
        // `didSet` does not fire inside `init`, so every migration below writes the value through to
        // UserDefaults itself. Without that the flag is set, the change lives for one process, and the
        // next launch reads the old value back with the migration already marked done.
        if !d.bool(forKey: "migratedEffortLow") { brainEffort = "low"; d.set("low", forKey: "brainEffort"); d.set(true, forKey: "migratedEffortLow") }
        if !d.bool(forKey: "migratedEffortNone") { brainEffort = "none"; d.set("none", forKey: "brainEffort"); d.set(true, forKey: "migratedEffortNone") }
        deepEffort = d.string(forKey: "deepEffort") ?? deepEffort
        realtimeModel = d.string(forKey: "realtimeModel") ?? realtimeModel
        ttsModel = d.string(forKey: "ttsModel") ?? ttsModel
        ttsVoice = d.string(forKey: "ttsVoice") ?? ttsVoice
        ttsStyle = d.string(forKey: "ttsStyle") ?? ttsStyle
        apiBaseURL = d.string(forKey: "apiBaseURL") ?? apiBaseURL
        apiStyle = d.string(forKey: "apiStyle") ?? apiStyle
        // The picker offers two styles. An older build could have stored "foundation", which every
        // screen already draws as OpenAI-compatible; make the stored value say the same thing rather
        // than leaving a third value nothing can select. (didSet does not fire inside init.)
        if apiStyle == "foundation" { apiStyle = "chat"; d.set("chat", forKey: "apiStyle") }
        ttsEngine = d.string(forKey: "ttsEngine") ?? ttsEngine
        userName = d.string(forKey: "userName") ?? userName
        writingStyle = d.string(forKey: "writingStyle") ?? writingStyle
        contextFiles = d.stringArray(forKey: "contextFiles") ?? contextFiles
        speakReplies = bool("speakReplies", speakReplies)
        soundsEnabled = bool("soundsEnabled", soundsEnabled)
        animateScreenshots = bool("animateScreenshots", animateScreenshots)
        screenAwareness = bool("screenAwareness", screenAwareness)
        alwaysScreenshot = bool("alwaysScreenshot", alwaysScreenshot)
        confirmActions = bool("confirmActions", confirmActions)
        deepMode = bool("deepMode", deepMode)
        defaultReminderList = d.string(forKey: "defaultReminderList") ?? defaultReminderList
        screenshotRetentionDays = d.object(forKey: "screenshotRetentionDays") as? Int ?? screenshotRetentionDays
        historyRetentionDays = d.object(forKey: "historyRetentionDays") as? Int ?? historyRetentionDays
        onboarded = bool("onboarded", onboarded)
        codingDefaultAgent = d.string(forKey: "codingDefaultAgent") ?? codingDefaultAgent
        codingAutoApprove = bool("codingAutoApprove", codingAutoApprove)
        talkKey = d.string(forKey: "talkKey") ?? talkKey
        composerShortcut = d.string(forKey: "composerShortcut") ?? composerShortcut
        handsFree = bool("handsFree", handsFree)
        wakeWord = d.string(forKey: "wakeWord") ?? wakeWord
        dictationProfile = d.string(forKey: "dictationProfile") ?? dictationProfile
        microphoneUID = d.string(forKey: "microphoneUID") ?? microphoneUID
        dictationVocabulary = d.string(forKey: "dictationVocabulary") ?? dictationVocabulary
        HotkeyMonitor.shared.talkKey = talkKey
        HotkeyMonitor.shared.composerShortcut = composerShortcut
    }

#if DEBUG
    /// `--preview-ui` renders screens with values it sets by hand — the default talk key, say — and
    /// runs against the real install's defaults domain. While this is on, nothing it sets is written.
    nonisolated(unsafe) static var suppressWritesForPreview = false
#endif

    private func save(_ k: String, _ v: Any) {
#if DEBUG
        if Settings.suppressWritesForPreview { return }
#endif
        d.set(v, forKey: k)
    }
    private func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }

    // Secrets (Keychain)
    nonisolated var openAIKey: String? { get { Keychain.get("openai") } set { Self.setSecret("openai", newValue) } }
    /// The brain provider's key. Same Keychain slot as `openAIKey` so existing installs keep working.
    nonisolated var apiKey: String? { get { openAIKey } set { openAIKey = newValue } }
    nonisolated var geminiKey: String? { get { Keychain.get("gemini") } set { Self.setSecret("gemini", newValue) } }
    nonisolated var fishKey: String? { get { Keychain.get("fish") } set { Self.setSecret("fish", newValue) } }
    nonisolated var xaiKey: String? { get { Keychain.get("xai") } set { Self.setSecret("xai", newValue) } }
    nonisolated var googleClientId: String? { get { Keychain.get("google_client_id") } set { Self.setSecret("google_client_id", newValue) } }
    nonisolated var googleClientSecret: String? { get { Keychain.get("google_client_secret") } set { Self.setSecret("google_client_secret", newValue) } }
    nonisolated var googleRefreshToken: String? {
        get { Keychain.get("google_refresh") }
        set { if let v = newValue { Keychain.set("google_refresh", v) } else { Keychain.delete("google_refresh") } }
    }
    nonisolated var googleAccountEmail: String? { get { Keychain.get("google_email") } set { Self.setSecret("google_email", newValue) } }

    private nonisolated static func setSecret(_ key: String, _ value: String?) {
        if let value { Keychain.set(key, value) } else { Keychain.delete(key) }
    }

    /// First run: import keys and tokens staged on disk by setup, then delete the staging file.
    ///
    /// Runs on the main thread during `applicationDidFinishLaunching`, so it touches the Keychain from
    /// there not at all. Reads obviously can block on a system access prompt this agent has no window to
    /// show; writes do not prompt themselves, but `Keychain.set` may still clear a legacy copy, which is
    /// the same authorized operation. So this does the file work inline and hands every Keychain call to a
    /// detached task.
    nonisolated func bootstrapSecretsFromDisk() {
        let staging = Paths.appSupport.appendingPathComponent("bootstrap-secrets.json")
        var staged: [String: String] = [:]
        if let data = try? Data(contentsOf: staging),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            staged = obj.filter { !$0.value.isEmpty }
            try? FileManager.default.removeItem(at: staging)
        }
        // No credentials file, no import: a file test, not a Keychain read.
        let hasOAuthFile = FileManager.default.fileExists(atPath: Paths.googleOAuthFile.path)
        guard !staged.isEmpty || hasOAuthFile else { return }
        Task.detached(priority: .utility) {
            if !staged.isEmpty {
                for (k, v) in staged { Keychain.set(k, v) }
                Log.info("Imported \(staged.count) secrets from bootstrap file")
            }
            // The bootstrap file just supplied a client; nothing to look up.
            guard staged["google_client_id"] == nil, hasOAuthFile else { return }
            Settings.importGoogleOAuthClient()
        }
    }

    /// Reads the OAuth client id and secret out of `Paths.googleOAuthFile`.
    /// Static and Keychain-only so it can run off the main actor.
    /// - Parameter force: replace a client that is already in the Keychain (the "Choose JSON…" button).
    @discardableResult
    nonisolated static func importGoogleOAuthClient(force: Bool = false) -> Bool {
        guard force || Keychain.get("google_client_id") == nil else { return false }
        guard let data = try? Data(contentsOf: Paths.googleOAuthFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let inst = (obj["installed"] as? [String: Any]) ?? obj
        guard let id = inst["client_id"] as? String, let sec = inst["client_secret"] as? String else { return false }
        Keychain.set("google_client_id", id)
        Keychain.set("google_client_secret", sec)
        Log.info("Imported the Google OAuth client from the credentials file")
        return true
    }

}

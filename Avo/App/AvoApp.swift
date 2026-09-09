import AppKit
import SwiftUI

@main
struct AvoMain {
    static func main() {
        #if DEBUG
        if DebugVerification.startIfRequested() { return }
        if DebugPreviews.startIfRequested() { return }
        #endif
        // The 2026-09-02 ViewBridge crashes (NSRemoteView on window order) left no exception reason in
        // the .ips report. Write name, reason and the top frames synchronously before the abort.
        NSSetUncaughtExceptionHandler { e in
            let frames = e.callStackSymbols.prefix(14).joined(separator: "\n")
            Log.errorSync("Uncaught \(e.name.rawValue): \(e.reason ?? "(no reason)")\n\(frames)")
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var talkHelpMenuItem: NSMenuItem?
    private let notch = NotchController.shared
    private var listening = false
    private var finalizing = false
    private var listenStartedAt: Date?
    private var micAuthorized = false
    private var listenGeneration = 0
    private var gestureGeneration: Int?
    /// AppKit delivers the GetURL AppleEvent from inside its launch sequence, before
    /// `applicationDidFinishLaunching` and long before tools are registered. URLs that arrive
    /// then wait here and run once the app is actually able to serve them.
    private var launchComplete = false
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Avo launching")
        // File-level migrations first: they must not be gated on the Keychain, which can block on a
        // system access prompt the first time a newly signed build reads a stored secret.
        MemoryTools.refreshFileHeader()
        Settings.shared.bootstrapSecretsFromDisk()
        setupMainMenu()
        setupStatusItem()
        notch.install()
        wireHotkey()
        micAuthorized = Transcriber.shared.permissionsGranted
        Transcriber.shared.warmUpEnabled = true
        Log.info("Launch: microphone authorized=\(micAuthorized)")
        HotkeyMonitor.shared.start()
        wireWakeWord()
        // Let the collapsed notch and input tap reach the first run loop before touching EventKit,
        // persisted task stores, or optional integrations. Those services are ready well before a
        // spoken request can finish, but no longer delay Avo becoming interactive.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self else { return }
            SideNotch.shared.install()
            Sounds.shared.prepare()
            GestureOverlay.shared.prepare()
            self.registerTools()
            LocalReminderScheduler.shared.start()
            SchedulingServices.shared.start()
            Retention.sweep()
            Transcriber.shared.warmUp()
            if !Settings.shared.onboarded {
                OnboardingWindow.shared.show()
                Log.info("Launch: onboarding window on screen")
            } else {
                self.ensurePermissionsQuietly()
            }
            if #available(macOS 26, *), Settings.shared.handsFree { WakeWord.shared.start() }
            self.launchComplete = true
            let queued = self.pendingURLs
            self.pendingURLs = []
            if !queued.isEmpty { Log.info("Open URL: running \(queued.count) queued at launch") }
            self.handle(queued)
        }
    }

    /// Hands-free: WakeWord captured an utterance after the wake phrase; run it like a released fn hold.
    private func wireWakeWord() {
        // WakeWord only exists on macOS 26; nothing posts this notification below that.
        guard #available(macOS 26, *) else { return }
        NotificationCenter.default.addObserver(forName: WakeWord.notification, object: nil, queue: .main) { [weak self] n in
            guard let self, let text = n.userInfo?["text"] as? String else { return }
            Task { @MainActor in self.notch.endListening(); await AgentRuntime.shared.run(text: text) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyMonitor.shared.stop()
        notch.uninstall()
    }

    /// Clicking the app icon (Dock/Finder/Launchpad) while running: show onboarding or the notch hint + settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !Settings.shared.onboarded { OnboardingWindow.shared.show() }
        else { notch.presentIdleHint(); SettingsWindow.shared.show() }
        return false
    }

    /// avo://ask?text=... runs a turn (used for testing and Shortcuts); avo://compose opens the composer; avo://settings.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard launchComplete else {
            for url in urls { Log.info("Open URL queued until launch finishes: \(url.absoluteString.prefix(200))") }
            pendingURLs.append(contentsOf: urls)
            return
        }
        handle(urls)
    }

    private func handle(_ urls: [URL]) {
        for url in urls {
            Log.info("Open URL: \(url.absoluteString.prefix(200))")
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            switch url.host {
            case "ask":
                if let t = comps?.queryItems?.first(where: { $0.name == "text" })?.value, !t.isEmpty {
                    notch.beginListening(); notch.model.transcript = t; notch.endListening()
                    Task { await AgentRuntime.shared.run(text: t) }
                }
            case "compose": notch.presentComposer()
            case "hittest": notch.debugHitTest()
            #if DEBUG
            // Verification only: opens the first-run flow, and caches every open window to PNG
            // (with its key/first-responder state in the log) without Screen Recording.
            case "onboarding": OnboardingWindow.shared.show()
            case "windows": DebugVerification.snapshotWindows(to: comps?.queryItems?.first(where: { $0.name == "dir" })?.value ?? "/tmp/avo-ui/live")
            case "click":
                let n = { (k: String) in CGFloat(Double(comps?.queryItems?.first(where: { $0.name == k })?.value ?? "") ?? 0) }
                DebugVerification.probeFocus(x: n("x"), y: n("y"))
            #endif
            case "settings": SettingsWindow.shared.show()
            case "voice": toggleVoiceMode()
            case "quit": quitAvo()
            case "restart":
                // Hand off to a detached waiter that reopens once this process is gone.
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-c", "for i in {1..25}; do pgrep -x Avo >/dev/null || break; sleep 0.2; done; sleep 0.5; for i in {1..5}; do open /Applications/Avo.app 2>/dev/null && break; sleep 0.5; done"]
                try? p.run()
                NSApp.terminate(nil)
            case "snapshot": notch.debugSnapshot(to: comps?.queryItems?.first(where: { $0.name == "path" })?.value ?? "/tmp/avo-notch.png")
            default: break
            }
        }
    }

    private func registerTools() {
        let r = ToolRegistry.shared
        r.register(AppleTools.all())
        r.register(TextTools.all())
        r.register(MemoryTools.all())
        r.register(PresentTools.all())
        r.register(GoogleTools.all())
        r.register(CodingTools.all())
        r.register(NotesTools.all())
        r.register(SchedulingTools.all())
        Log.info("Registered \(r.all.count) tools")
        Task { ToolRegistry.shared.register(await MCPTools.all()); Log.info("Registered \(ToolRegistry.shared.all.count) tools incl. MCP") }
    }

    private func wireHotkey() {
        let h = HotkeyMonitor.shared
        h.onPress = { [weak self] in self?.beginListening() }
        h.onRelease = { [weak self] held in self?.endListening(held: held) }
        h.onCancel = { [weak self] in self?.cancelListening() }
        h.onComposer = { [weak self] in
            guard let self else { return }
            if self.listening || self.finalizing { self.cancelListening() }
            self.notch.presentComposer()
        }
        h.onEscape = { [weak self] in
            guard let self else { return }
            if self.listening || self.finalizing { self.cancelListening(); return }
            guard self.notch.model.expanded else { return }
            AgentRuntime.shared.cancel(); Speech.shared.stop(); self.notch.collapse()
        }
    }

    private func beginListening() {
        guard !listening else { return }
        listenGeneration += 1
        let generation = listenGeneration
        listening = true
        finalizing = false
        listenStartedAt = Date()
        ScreenCaptureFlight.shared.cancel()
        Log.info("Listen: begin")
        // Do not cold-start the TTS audio graph just to stop silence. Stop only when speech is playing
        // or queued/synthesizing, so a reply that has not started yet cannot begin over the new hold.
        if notch.model.speaking || Speech.shared.isBusy { Speech.shared.stop() }
        // A turn parked on a confirmation/question card keeps waiting: what follows is most likely
        // its answer ("yes", "make it 7:30"). Cancelling here resolved the card as cancelled before
        // the user had finished speaking, and "yes" then started an unrelated turn.
        let awaitingCard = AgentRuntime.shared.isAwaitingUser
        if AgentRuntime.shared.isRunning, !awaitingCard { AgentRuntime.shared.cancel() }
        // Start input before asking Core Audio to bring up the optional output chime.
        notch.beginListening(keepingCards: awaitingCard, playSound: false)
        if !awaitingCard {
            if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier { ContextBuilder.shared.previousApp = app }
            ContextBuilder.shared.capturePreActivationContext()
        }
        gestureGeneration = Settings.shared.screenAwareness ? GestureOverlay.shared.begin() : nil
        Task {
            if !micAuthorized { micAuthorized = await Transcriber.shared.requestPermissions() }
            guard listening, generation == listenGeneration else { return }
            guard micAuthorized else {
                // Denied (or the prompt was dismissed): don't start a silent capture that ends in "Didn't catch that."
                listening = false
                if let gestureGeneration { GestureOverlay.shared.discard(generation: gestureGeneration) }
                gestureGeneration = nil
                ContextBuilder.shared.discardDraft()
                notch.fail("Microphone or Speech Recognition access is off. Enable both for Avo in System Settings → Privacy & Security.")
                return
            }
            Transcriber.shared.onUpdate = { [weak self] text, level in
                guard let self, self.listenGeneration == generation, self.listening || self.finalizing else { return }
                self.notch.updateTranscript(text, level: level)
            }
            if await Transcriber.shared.start() {
                guard listening, generation == listenGeneration else { return }
                notch.model.microphoneReady = true
                Log.info("Voice timing: key-to-mic=\(Int(Date().timeIntervalSince(listenStartedAt ?? Date()) * 1000))ms")
                Sounds.shared.play(.listenStart)
            } else if listening, generation == listenGeneration {
                listening = false
                if let gestureGeneration { GestureOverlay.shared.discard(generation: gestureGeneration) }
                gestureGeneration = nil
                ContextBuilder.shared.discardDraft()
                notch.fail("Couldn't start the microphone. Check the input selected in Voice settings and try again.")
            }
        }
    }

    private func endListening(held: TimeInterval) {
        guard listening else { return }
        let generation = listenGeneration
        let endingGestureGeneration = gestureGeneration
        gestureGeneration = nil
        listening = false
        finalizing = true
        notch.model.finalizingSpeech = true
        notch.model.audioLevel = 0
        let releasedAt = Date()
        Log.info("Listen: end after \(String(format: "%.2f", held))s")
        Task {
            // Capture (off the main thread) and transcript finalisation run concurrently.
            let shotsTask: Task<[String], Never> = Task {
                guard let endingGestureGeneration else { return [] }
                return await GestureOverlay.shared.end(generation: endingGestureGeneration)
            }
            // Snappy: when nothing was heard live, close immediately instead of waiting on the finalizer.
            let awaitingCard = AgentRuntime.shared.isAwaitingUser
            let liveEmpty = notch.model.transcript.rangeOfCharacter(from: .alphanumerics) == nil
            if liveEmpty, held < 0.35, !awaitingCard { notch.collapse() }
            let captureTask: Task<Void, Never> = Task {
                let marks = await shotsTask.value
                guard generation == listenGeneration, !awaitingCard else { return }
                if !marks.isEmpty {
                    ContextBuilder.shared.setGestureShots(marks)
                    let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.notchScreen
                    notch.showScreenChip(path: marks[0], state: .running, fly: Settings.shared.animateScreenshots, from: screen.frame)
                } else if !liveEmpty {
                    await ContextBuilder.shared.captureAfterSpeech(hint: notch.model.transcript)
                }
            }
            let text = await Transcriber.shared.stop()
            await captureTask.value
            guard generation == listenGeneration else { return }
            Log.info("Listen: transcript '\(text.prefix(120))'")
            let shots = await shotsTask.value
            guard generation == listenGeneration else { return }
            finalizing = false
            notch.model.finalizingSpeech = false
            Log.info("Voice timing: release-to-transcript=\(Int(Date().timeIntervalSince(releasedAt) * 1000))ms")
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasSpeech = normalized.rangeOfCharacter(from: .alphanumerics) != nil
            if !hasSpeech {
                if awaitingCard {
                    ContextBuilder.shared.discardDraft()
                    // Nothing said while a card waits: put the card back in front, keep waiting.
                    notch.resumeCard()
                    return
                }
                if liveEmpty { Log.info("Listen: empty capture cancelled quietly") }
                ContextBuilder.shared.discardDraft()
                notch.collapse()
                if held < 0.35, Settings.shared.shortTapOpensComposer, liveEmpty {
                    // Dedicated talk keys retain the convenient tap-to-type gesture.
                    ContextBuilder.shared.pendingGestureShots = shots
                    Log.info("Listen: silent dedicated-key tap opened composer")
                    notch.presentComposer()
                }
                return
            }
            ContextBuilder.shared.setGestureShots(shots)
            if liveEmpty, !awaitingCard { await ContextBuilder.shared.captureAfterSpeech(hint: normalized) }
            guard generation == listenGeneration else { return }
            // presentTurn resets the model; with a card pending that would wipe the card mid-wait.
            if liveEmpty, !awaitingCard { notch.presentTurn(normalized) } else { notch.endListening() }
            await AgentRuntime.shared.run(text: normalized)
        }
    }

    private func cancelListening() {
        guard listening || finalizing else { return }
        listenGeneration += 1
        listening = false
        finalizing = false
        ContextBuilder.shared.discardDraft()
        ScreenCaptureFlight.shared.cancel()
        if let gestureGeneration { GestureOverlay.shared.discard(generation: gestureGeneration) }
        gestureGeneration = nil
        ContextBuilder.shared.pendingGestureShots = []
        Transcriber.shared.cancel()
        // Collapsing while a card waits would reset the model 0.45 s later and orphan the continuation.
        if AgentRuntime.shared.isAwaitingUser { notch.resumeCard() } else { notch.collapse() }
    }

    /// Only the four permissions the hold-to-talk loop needs. Screen Recording, Reminders, Location
    /// and Full Disk Access are asked for by PermissionGate when a tool first needs them.
    private func ensurePermissionsQuietly() {
        Task {
            micAuthorized = await Transcriber.shared.requestPermissions()
            // Launch deferred the audio warm-up while the prompt was unanswered; run it now.
            if micAuthorized { Transcriber.shared.permissionDidChange() }
        }
        if !Permissions.inputMonitoring { Permissions.requestInputMonitoring() }
        if !Permissions.accessibility { Permissions.requestAccessibility() }
    }

    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        let quitItem = appMenu.addItem(withTitle: "Quit Avo", action: #selector(quitAvo), keyEquivalent: "q")
        quitItem.target = self
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            let mark = NSImage(named: "MenuBarIcon")
            mark?.isTemplate = true
            mark?.accessibilityDescription = "Avo"
            b.image = mark
        }
        let menu = NSMenu()
        let talkHelp = NSMenuItem(title: "Hold \(Settings.shared.talkKeyLabel) to talk", action: nil, keyEquivalent: "")
        talkHelpMenuItem = talkHelp
        menu.addItem(talkHelp)
        menu.addItem(withTitle: "Type to Avo…", action: #selector(typeToAvo), keyEquivalent: "t")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Voice Mode", action: #selector(toggleVoiceMode), keyEquivalent: "v")
        menu.addItem(withTitle: "History", action: #selector(showHistory), keyEquivalent: "h")
        let side = NSMenuItem(title: "Side notch", action: #selector(toggleSideNotch(_:)), keyEquivalent: "")
        side.state = SideNotch.shared.enabled ? .on : .off
        menu.addItem(side)
        menu.addItem(withTitle: "Connect Google…", action: #selector(connectGoogle), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Avo", action: #selector(quitAvo), keyEquivalent: "q")
        for i in menu.items { i.target = self }
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        talkHelpMenuItem?.title = "Hold \(Settings.shared.talkKeyLabel) to talk"
    }

    @objc private func typeToAvo() { notch.presentComposer() }
    @objc private func toggleVoiceMode() { VoiceModeSession.shared.toggle() }
    @objc private func showHistory() { HistoryWindow.shared.show() }
    @objc private func toggleSideNotch(_ sender: NSMenuItem) {
        SideNotch.shared.setEnabled(!SideNotch.shared.enabled)
        sender.state = SideNotch.shared.enabled ? .on : .off
    }
    @objc private func showSettings() { SettingsWindow.shared.show() }
    @objc private func quitAvo() { NSApp.terminate(nil) }
    @objc private func connectGoogle() {
        Task {
            do {
                let email = try await GoogleAuth.shared.signIn()
                notch.setResponse("Google connected: \(email)"); notch.reveal(); notch.done()
            } catch {
                notch.reveal(); notch.fail("Google sign-in failed: \(error.localizedDescription)")
            }
        }
    }
}

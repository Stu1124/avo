#if DEBUG
import AppKit
import SwiftUI

/// Isolated verification entry points. None of them starts a hotkey, a microphone, or a watch.
/// `--ask` is the one exception on tools: it registers the real registry, so a turn it drives can pick an
/// acting tool and that tool will really run. Drive it only with prompts whose expected route is read-only.
@MainActor
enum DebugVerification {
    static func startIfRequested() -> Bool {
        guard let mode = CommandLine.arguments.dropFirst().first, ["--ask", "--verify-cache", "--verify-context", "--verify-flow", "--preview-voice", "--preview-composer", "--preview-capture", "--preview-settings", "--preview-onboarding"].contains(mode) else { return false }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task {
            switch mode {
            case "--ask": await ask()
            case "--verify-cache": await verifyCache()
            case "--verify-context": await verifyContext()
            case "--verify-flow": await verifyFlow()
            case "--preview-capture": await previewCapture()
            case "--preview-settings": await previewSettings()
            case "--preview-onboarding": await previewOnboarding()
            default: await preview(review: mode == "--preview-composer")
            }
            exit(0)
        }
        NSApp.run()
        return true
    }

    /// `--ask "<text>"` runs one real turn and exits, so tool routing can be compared across builds.
    /// Registers the eight built-in tool groups — MCP tools are not loaded, so the set is the app's minus
    /// any remote tools. No hotkey, microphone, or wake word. A watchdog exits(2) if the turn stalls.
    private static let askTimeout: UInt64 = 120
    private static func ask() async {
        let text = CommandLine.arguments.dropFirst(2).first ?? ""
        guard !text.isEmpty else { print("ASK: no text given"); return }
        Settings.shared.bootstrapSecretsFromDisk()
        let r = ToolRegistry.shared
        r.register(AppleTools.all())
        r.register(TextTools.all())
        r.register(MemoryTools.all())
        r.register(PresentTools.all())
        r.register(GoogleTools.all())
        r.register(CodingTools.all())
        r.register(NotesTools.all())
        r.register(SchedulingTools.all() + WebTools.all())
        Log.info("Registered \(r.all.count) tools")
        NotchController.shared.install()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: askTimeout * 1_000_000_000)
            guard !Task.isCancelled else { return }
            Log.error("ASK: no answer within \(askTimeout)s — giving up")
            print("ASK timeout after \(askTimeout)s: \(text)")
            exit(2)
        }
        await AgentRuntime.shared.run(text: text)
        watchdog.cancel()
        try? await Task.sleep(nanoseconds: 300_000_000)
        print("ASK done: \(text)")
    }

    /// Caches each on-screen window's content view to a PNG and logs its focus state. Uses
    /// `cacheDisplay`, so it works with no Screen Recording permission — the only way to see the
    /// live windows during verification — and the log line is the evidence for where focus went.
    static func snapshotWindows(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (i, w) in NSApp.windows.enumerated() where w.isVisible {
            let name = w.title.isEmpty ? "window-\(i)" : w.title.replacingOccurrences(of: " ", with: "-").lowercased()
            Log.info("Window \(name): appActive=\(NSApp.isActive) key=\(w.isKeyWindow) canBecomeKey=\(w.canBecomeKey) "
                     + "level=\(w.level.rawValue) keyLoop=\(w.autorecalculatesKeyViewLoop) "
                     + "movableByBackground=\(w.isMovableByWindowBackground) firstResponder=\(responder(w))")
            guard let v = w.contentView, v.bounds.width > 1, v.bounds.height > 1,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
        }
    }

    /// The dynamic class of a window's first responder, which is what tells a caret from nothing.
    private static func responder(_ w: NSWindow) -> String {
        guard let r = w.firstResponder else { return "nil" }
        return String(describing: type(of: r))
    }

    /// Verification only: clicks the key window at a point in its own coordinates (origin bottom-left)
    /// by posting a real mouse event, then logs where first responder ended up. This is the only way
    /// to prove a click focuses a text field on a Mac where Accessibility cannot drive the pointer.
    static func probeFocus(x: CGFloat, y: CGFloat) {
        // Prefer a real titled window: the notch panel is borderless, keyable and always on screen,
        // so a naive "first window that can become key" picks it every time.
        guard let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey && $0.styleMask.contains(.titled) }) else {
            Log.warn("probeFocus: no titled window on screen"); return
        }
        Log.info("probeFocus before: window=\(w.title) appActive=\(NSApp.isActive) key=\(w.isKeyWindow) firstResponder=\(responder(w))")
        let at = NSPoint(x: x, y: y)
        for (kind, n) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 2)] {
            if let e = NSEvent.mouseEvent(with: kind, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: n, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0) {
                w.sendEvent(e)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let r = w.firstResponder
            let editing = r is NSTextView || r is NSText
            Log.info("probeFocus after (\(Int(x)),\(Int(y))): key=\(w.isKeyWindow) firstResponder=\(responder(w)) "
                     + "editingTextField=\(editing) hasCaret=\((r as? NSTextView)?.shouldDrawInsertionPoint ?? false)")
        }
    }

    /// Exercises the three things this task changed that only show up at runtime: what Detect reports
    /// when no Ollama answers, what the single voice-mode gate does to a start from any entry point,
    /// and what a denied permission does to a tool. Then opens onboarding, clicks its first text
    /// field with a synthesized event, and mirrors a turn into the try-it step.
    ///
    /// `--verify-flow <step>` picks which onboarding step to open (default 1, the Brain step).
    private static func verifyFlow() async {
        let step = Int(CommandLine.arguments.dropFirst(2).first ?? "") ?? 1
        let notch = NotchController.shared
        notch.install()

        // 1 · Ollama detection: one GET, and nothing when nothing answers.
        let found = await OllamaDetect.models()
        let detect: String
        if let found, !found.isEmpty { detect = "Ollama found: \(found.prefix(4).joined(separator: ", "))" }
        else if found != nil { detect = "Ollama is running but has no models. Try: ollama pull llama3.2" }
        else { detect = "No Ollama at localhost:11434." }
        print("DETECT: \(detect)")

        // 2 · The voice-mode gate. Settings, the menu item and avo://voice all land here.
        print("VOICE reason: \(VoiceModeSession.unavailableReason ?? "(available)")")
        await VoiceModeSession.shared.start()
        try? await Task.sleep(nanoseconds: 400_000_000)
        print("VOICE active=\(VoiceModeSession.shared.isActive) notchError=\(notch.model.errorText ?? "(none)")")

        // 3 · A just-in-time gate on a permission this build does not have.
        let allowed = await PermissionGate.ensure(.screenRecording)
        print("GATE screenRecording allowed=\(allowed)")
        print("GATE guidance: \(PermissionGate.guidance(.screenRecording))")
        try? await Task.sleep(nanoseconds: 500_000_000)
        notch.debugSnapshot(to: "/tmp/avo-ui/gate-card.png")

        // 3b · Regression: the card has to come back after the notch is cleared. Every talk-key press
        // runs `NotchController.beginListening` → `model.reset()`, which empties `cards` without the
        // card's own answer handler ever running. A gate that only remembered "already shown" went
        // silent for the rest of the session from that point on.
        print("GATE cards after first block=\(notch.model.cards.count)")
        notch.model.reset()
        print("GATE cards after reset=\(notch.model.cards.count)")
        let again = await PermissionGate.ensure(.screenRecording)
        print("GATE screenRecording second allowed=\(again) cards=\(notch.model.cards.count)")

        // 3c · A Finder read into a Full-Disk-Access location must report the permission, not "not
        // found". `~/Library/Mail` is protected on every Mac and needs no personal data to probe.
        let mail = Paths.home.appendingPathComponent("Library/Mail").path
        print("GATE finder fda=\(Permissions.fullDiskAccess) refused=\(FinderTools.permissionDenied(mail))")
        if let gated = await FinderTools.fullDiskGate(mail) {
            print("GATE finder error=\(gated.json["error"] ?? "-") guidance=\(gated.json["guidance"] ?? "-")")
        } else {
            print("GATE finder: path readable, no gate needed")
        }
        notch.model.reset()

        // 4 · Onboarding, live: open it, click into the Brain step's first field, snapshot.
        UserDefaults.standard.set(step, forKey: "onboardingDebugStep")
        OnboardingWindow.shared.show()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        if step == 1 { probeFocus(x: 472, y: 353) }          // centre of the Base URL field
        // 5 · Mirror a turn into the try-it step without calling a model.
        if step == 3 {
            notch.presentTurn("what time is it")
            notch.model.responseText = "It's 12:40 AM."
        }
        try? await Task.sleep(nanoseconds: 900_000_000)
        snapshotWindows(to: "/tmp/avo-ui/live-\(step)")
        try? await Task.sleep(nanoseconds: 400_000_000)
        UserDefaults.standard.removeObject(forKey: "onboardingDebugStep")
        print("PASS: flow verified (step \(step))")
    }

    private static func verifyCache() async {
        // Local providers (Ollama, LM Studio) need no key; only the hosted OpenAI path does.
        if Settings.shared.isOpenAIHost, Settings.shared.apiKey?.isEmpty != false { print("BLOCKED: API key unavailable"); return }
        let groups = AppleTools.all() + TextTools.all() + MemoryTools.all() + PresentTools.all() + GoogleTools.all() + CodingTools.all() + NotesTools.all() + SchedulingTools.all()
        let definitions = groups.map { $0.openAIDefinition }
        let client = Brain.client()
        let prompt = SystemPrompt.build(includeVoice: false)
        var results: [[String: Any]] = []
        for index in 1...2 {
            let start = Date()
            let input: [[String: Any]] = [["role": "user", "content": [["type": "input_text", "text": "Connection check \(index). Reply only OK. Do not call any tools."]]]]
            var result: [String: Any] = ["request": index]
            for await event in client.stream(model: Settings.shared.brainModel, effort: "none", instructions: prompt, input: input, tools: definitions) {
                switch event {
                case .completed(_, let usage):
                    result["usage"] = usage
                    if let usage, Brain.style == .responses { result["estimated_token_usd"] = RequestPolicy.Usage(usage).estimatedUSD(model: Settings.shared.brainModel) }
                case .error(let error): result["error"] = error
                case .toolCall: result["unexpected_tool_call"] = true
                default: break
                }
            }
            result["elapsed_ms"] = Int(Date().timeIntervalSince(start) * 1000)
            results.append(result)
            if result["error"] != nil { break }
        }
        let data = try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try? data.write(to: URL(fileURLWithPath: "/tmp/avo-cache-verification.json"))
        print(String(decoding: data, as: UTF8.self))
    }

    private static func verifyContext() async {
        let builder = ContextBuilder.shared
        builder.loadVerificationDraft()
        let snap = await builder.build(turnId: UUID(), transcript: "Summarize this")
        precondition(snap.clipboard == nil && snap.focusedText == nil)
        precondition(builder.verificationDraftIsEmpty)
        builder.loadVerificationDraft(selectedText: nil)
        let empty = await builder.build(turnId: UUID(), transcript: "No selection")
        precondition(empty.selectedText == nil && empty.clipboard == nil && empty.focusedText == nil)
        builder.loadVerificationDraft()
        let included = await builder.build(turnId: UUID(), transcript: "Use the selection")
        precondition(included.selectedText == "Move the review to Thursday at 3." && included.focusedText == nil)
        precondition(included.imagePaths == (Settings.shared.screenAwareness ? ["/tmp/avo-context-fixture.jpg"] : []))
        builder.loadVerificationDraft()
        builder.setGestureShots(["/tmp/marked.jpg"])
        let marked = await builder.build(turnId: UUID(), transcript: "Explain this")
        precondition(marked.imagePaths == (Settings.shared.screenAwareness ? ["/tmp/marked.jpg"] : []), "Marked target replaces the ambient screenshot")
        builder.loadVerificationDraft()
        builder.discardDraft()
        precondition(builder.verificationDraftIsEmpty)
        print("PASS: selected text only, no clipboard/window fallback, marked-region deduplication, draft cleanup")
    }

    private static func previewCapture() async {
        let notch = NotchController.shared
        notch.install()
        notch.beginListening(playSound: false)
        notch.model.transcript = "What is on this screen?"
        notch.model.finalizingSpeech = true
        guard let path = await ScreenCapture.shared.captureMain(maxWidth: 1600) else { print("BLOCKED: screen recording permission"); return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.notchScreen
        ScreenCaptureFlight.shared.present(path: path, from: screen.frame)
        try? await Task.sleep(nanoseconds: 130_000_000)
        notch.debugSnapshot(to: "/tmp/avo-flight-start.png")
        try? await Task.sleep(nanoseconds: 220_000_000)
        notch.debugSnapshot(to: "/tmp/avo-flight-middle.png")
        try? await Task.sleep(nanoseconds: 260_000_000)
        notch.debugSnapshot(to: "/tmp/avo-flight-end.png")
        try? await Task.sleep(nanoseconds: 600_000_000)
        ScreenCaptureFlight.shared.cancel()
        notch.uninstall()
        print("PASS: captured screen, rendered flight, released overlay")
    }

    /// Renders a settings page to PNG without touching the real Settings window.
    private static func previewSettings() async {
        await renderToPNG(AnyView(GeneralPage(s: Settings.shared)), width: 660, path: "/tmp/avo-ui/settings-general.png")
        await renderToPNG(AnyView(KeysPage()), width: 660, path: "/tmp/avo-ui/settings-keys.png")
        // A model of its own, never started: the render must not leave a polling timer behind.
        await renderToPNG(AnyView(PermissionsPage(model: PermissionsModel())), width: 660, path: "/tmp/avo-ui/settings-permissions.png")
        print("PASS: rendered Settings → General, Keys and Permissions")
    }

    /// Renders every onboarding step to PNG. The permissions model is never started.
    private static func previewOnboarding() async {
        for step in 0..<6 {
            var view = OnboardingView(permissions: PermissionsModel(), settings: Settings.shared,
                                      preview: VoicePreview.shared, notch: NotchController.shared.model, onFinish: {})
            view.debugInitialStep = step
            await renderToPNG(AnyView(view), width: OnboardingWindow.size.width, height: OnboardingWindow.size.height, pad: 0, path: "/tmp/avo-ui/onboarding-\(step).png")
        }
        print("PASS: rendered 6 onboarding steps")
    }

    /// Hosts a view in an off-to-the-side dark window, lets it lay out, then caches the display into a PNG.
    /// Scaled down when the natural height would not fit on screen, so nothing is cropped.
    /// `pad` is 0 for a whole window's content, which already carries its own margins.
    private static func renderToPNG(_ view: AnyView, width: CGFloat, height: CGFloat? = nil, pad: CGFloat = 24, path: String) async {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let limit: CGFloat = 940
        let padded = AnyView(view.frame(width: width).padding(pad))
        var h = height ?? NSHostingView(rootView: padded).fittingSize.height
        var scale: CGFloat = 1
        if h > limit { scale = limit / h; h = limit }
        let w = (width + pad * 2) * scale
        let root = padded.scaleEffect(scale, anchor: .topLeading).frame(width: w, height: h, alignment: .topLeading)
            .background(Color.black.opacity(0.92))
        let win = DarkWindow.make(title: "Preview", size: NSSize(width: w, height: h), content: root)
        win.setFrameOrigin(NSPoint(x: 0, y: 0))
        win.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 900_000_000)
        if let v = win.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                print("wrote \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh), scale \(String(format: "%.2f", scale)))")
            }
        }
        win.orderOut(nil)
        win.close()
    }

    private static func preview(review: Bool) async {
        let notch = NotchController.shared
        notch.install()
        ContextBuilder.shared.loadVerificationDraft()
        if review {
            notch.presentComposer()
            notch.model.composerText = "Move the review to Thursday at 3."
        } else {
            notch.beginListening(playSound: false)
            notch.model.microphoneReady = true
            notch.model.transcript = "Move the review to Thursday at 3."
            notch.model.audioLevel = 0.45
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        notch.debugSnapshot(to: review ? "/tmp/avo-review-preview.png" : "/tmp/avo-voice-preview.png")
        // Optional interactive inspection without activating any integrations.
        if CommandLine.arguments.contains("--interactive") {
            try? await Task.sleep(nanoseconds: 240_000_000_000)
        }
        notch.uninstall()
    }
}
#endif

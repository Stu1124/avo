#if DEBUG
import AppKit
import SwiftUI

/// UI review renders. Screen Recording is denied to agent processes, so every screen Avo has is
/// drawn into an off-screen window and cached to a PNG instead. Nothing here starts a microphone,
/// a hotkey tap, a watch, or an acting tool.
///
/// `Avo --preview-ui [dir]` writes one PNG per screen into `dir` (default `/tmp/avo-ui/polish`).
@MainActor
enum DebugPreviews {
    static func startIfRequested() -> Bool {
        guard CommandLine.arguments.dropFirst().first == "--preview-ui" else { return false }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Keychain.suppressReadsForPreview = true
        Settings.suppressWritesForPreview = true
        let dir = CommandLine.arguments.dropFirst(2).first ?? "/tmp/avo-ui/polish"
        // Optional third argument names one screen group, so a single window can be iterated on
        // without re-rendering all twenty.
        let only = CommandLine.arguments.dropFirst(3).first
        Task {
            if let only {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                switch only {
                case "onboarding": await renderOnboarding(dir)
                case "settings": await renderSettings(dir)
                case "notch": await renderNotch(dir)
                default: await renderAll(into: dir)
                }
                print("PASS: rendered \(only) into \(dir)")
            } else {
                await renderAll(into: dir)
            }
            exit(0)
        }
        NSApp.run()
        return true
    }

    static func renderAll(into dir: String) async {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        await renderSettings(dir)
        await renderOnboarding(dir)
        await renderHistory(dir)
        await renderSideNotch(dir)
        await renderNotch(dir)
        print("PASS: rendered every screen into \(dir)")
    }

    // MARK: Settings, onboarding, history, side notch

    private static func renderSettings(_ dir: String) async {
        let s = Settings.shared
        // The Apps page is a list of registered tools; with none registered the render says nothing.
        // Only the pure builders — no watches, schedulers or MCP discovery.
        if ToolRegistry.shared.all.isEmpty {
            ToolRegistry.shared.register(TextTools.all() + MemoryTools.all() + PresentTools.all() + CodingTools.all())
        }
        await render(AnyView(GeneralPage(s: s)), width: 660, path: "\(dir)/settings-general.png")
        await render(AnyView(VoicePage(s: s, preview: VoicePreview.shared)), width: 660, path: "\(dir)/settings-voice.png")
        await render(AnyView(AppsPage(model: ToolGroupsModel())), width: 660, path: "\(dir)/settings-apps.png")
        await render(AnyView(GooglePage()), width: 660, path: "\(dir)/settings-google.png")
        await render(AnyView(CodingPage(s: s)), width: 660, path: "\(dir)/settings-coding.png")
        await render(AnyView(KeysPage()), width: 660, path: "\(dir)/settings-keys.png")
        // A model of its own, never started: no polling timer is left behind.
        await render(AnyView(PermissionsPage(model: PermissionsModel())), width: 660, path: "\(dir)/settings-permissions.png")
        await render(AnyView(AboutPage(s: s)), width: 660, path: "\(dir)/settings-about.png")
    }

    private static func renderOnboarding(_ dir: String) async {
        // The Welcome stage loops on a timer; pin it to the last beat so the render is the same
        // picture every time rather than a race with the clock.
        OnboardingStagePreview.beat = 4
        defer { OnboardingStagePreview.beat = nil }
        // Onboarding names the talk key throughout. Render the default a first-time user sees,
        // not whatever this machine happens to be set to. This is a display override; the stored setting is never touched.
        Settings.previewTalkKeyOverride = "fn"
        defer { Settings.previewTalkKeyOverride = nil }
        let m = NotchController.shared.model
        for step in 0..<6 {
            // Step 4 mirrors the notch. Give it a finished turn so the mirror is not an empty box.
            if step == 3 {
                m.transcript = "What time is it"
                m.responseText = "It's 4:12 PM."
                m.phase = .done
            }
            var view = OnboardingView(permissions: PermissionsModel(), settings: Settings.shared,
                                      preview: VoicePreview.shared, notch: m, onFinish: {})
            view.debugInitialStep = step
            await render(AnyView(view), width: OnboardingWindow.size.width, height: OnboardingWindow.size.height,
                         pad: 0, path: "\(dir)/step-\(step).png")
            if step == 3 { m.reset() }
        }
    }

    private static func renderHistory(_ dir: String) async {
        await render(AnyView(HistoryView(history: History.shared)), width: 600, height: 680, pad: 0, path: "\(dir)/history.png")
    }

    private static func renderSideNotch(_ dir: String) async {
        let model = SideNotchModel()
        model.out = true
        model.working = [sampleTask(status: "running"), sampleTask(status: "waiting")]
        model.done = [sampleTask(status: "done")]
        await render(AnyView(SideNotchPanelBody(model: model, history: History.shared, controller: SideNotch.shared)),
                     width: SideNotch.panelWidth, pad: 12, path: "\(dir)/side-notch.png")
    }

    private static func sampleTask(status: String) -> CodingTask {
        CodingTask(id: String(UUID().uuidString.prefix(6)), agent: "claude",
                   title: status == "waiting" ? "Needs your answer" : "Tidy the settings page",
                   project: "/Projects/demo", instruction: "Tidy the settings page", mode: "code",
                   status: status, activity: ["Reading DesignSystem.swift", "Editing SettingsViews.swift"],
                   createdAt: Date().addingTimeInterval(-240))
    }

    // MARK: Notch

    /// The notch surface itself, in each of the four states plus the three cards. Rendered off-screen
    /// at the width the controller gives it, so the PNG is the panel's own glass, not a screenshot.
    private static func renderNotch(_ dir: String) async {
        let controller = NotchController.shared
        let m = controller.model

        m.reset()
        await renderNotchSurface(m, controller, dir: dir, name: "notch-collapsed")

        // Same state with the pointer over the notch: a little taller and wider, faint accent glow.
        m.reset()
        m.collapsedHover = true
        await renderNotchSurface(m, controller, dir: dir, name: "notch-hover")
        m.collapsedHover = false

        m.reset()
        m.expanded = true
        m.phase = .listening
        m.microphoneReady = true
        m.transcript = "Move the review to Thursday at three"
        m.audioLevel = 0.55
        await renderNotchSurface(m, controller, dir: dir, name: "notch-listening")

        m.reset()
        m.expanded = true
        m.phase = .thinking
        m.transcript = "What's on my calendar tomorrow?"
        m.statusChips = [.init(id: UUID(), icon: "calendar", label: "Calendar", state: .running)]
        await renderNotchSurface(m, controller, dir: dir, name: "notch-thinking")

        m.reset()
        m.expanded = true
        m.phase = .done
        m.transcript = "What's on my calendar tomorrow?"
        m.responseText = "Three things: **standup** at 9:30, a design review at 1, and dinner at 7.\n\n- Standup, 9:30 AM\n- Design review, 1:00 PM\n- Dinner, 7:00 PM"
        m.statusChips = [.init(id: UUID(), icon: "calendar", label: "Calendar", state: .done)]
        await renderNotchSurface(m, controller, dir: dir, name: "notch-reply")

        m.reset()
        m.expanded = true
        m.phase = .done
        m.transcript = "Text Sam that I'm running late"
        m.cards = [AnyCard(id: confirmationSample.id, kind: .confirmation(confirmationSample))]
        await renderNotchSurface(m, controller, dir: dir, name: "card-confirmation")

        m.reset()
        m.expanded = true
        m.phase = .done
        m.transcript = "What's on my calendar tomorrow?"
        m.cards = [AnyCard(id: glanceSample.id, kind: .glance(glanceSample))]
        await renderNotchSurface(m, controller, dir: dir, name: "card-glance")

        m.reset()
        m.expanded = true
        m.phase = .done
        m.transcript = "Book the flight"
        m.cards = [AnyCard(id: questionSample.id, kind: .question(questionSample))]
        await renderNotchSurface(m, controller, dir: dir, name: "card-question")

        m.reset()
    }

    private static func renderNotchSurface(_ m: NotchModel, _ c: NotchController, dir: String, name: String) async {
        let width = m.expanded ? NotchController.expandedWidth + 40 : 260
        await render(AnyView(NotchSurface(model: m, controller: c)), width: width, pad: 16,
                     background: Color(white: 0.16), path: "\(dir)/\(name).png")
    }

    private static var confirmationSample: ConfirmationCard {
        ConfirmationCard(id: UUID(), icon: "app:com.apple.MobileSMS", title: "Send iMessage", subtitle: "to Sam",
                         fields: [.init(id: "recipient", label: "To", kind: .text, value: "Sam", required: true),
                                  .init(id: "message", label: "Message", kind: .multiline, value: "Running about ten minutes late — start without me.", required: true)],
                         confirmLabel: "Send", layout: .message)
    }

    private static var glanceSample: GlanceCard {
        GlanceCard(id: UUID(), blocks: [
            .header(title: "Tomorrow", subtitle: "Wednesday, 3 events", icon: "calendar"),
            .list(rows: [
                .init(title: "Standup", subtitle: "9:30 – 9:45 AM", icon: "person.2.fill", trailing: "15m", accent: "#3B82F6"),
                .init(title: "Design review", subtitle: "1:00 – 2:00 PM", icon: "pencil.and.ruler", trailing: "1h", accent: "#F59E0B"),
                .init(title: "Dinner", subtitle: "7:00 PM", icon: "fork.knife", trailing: "2h", accent: "#22C55E"),
            ]),
        ], source: "Calendar", sourceIcon: "calendar")
    }

    private static var questionSample: QuestionCard {
        QuestionCard(id: UUID(), icon: "questionmark.circle", title: "Which flight?",
                     body: "Two options fit the window you gave me.",
                     options: ["7:15 AM, nonstop", "11:40 AM, one stop"], allowFreeText: true)
    }

    // MARK: Renderer

    /// Hosts a view in an off-screen dark window, lets it lay out, then caches the display to PNG.
    /// Scaled down when the natural height would not fit, so nothing is cropped.
    private static func render(_ view: AnyView, width: CGFloat, height: CGFloat? = nil, pad: CGFloat = 24,
                               background: Color = Color.black.opacity(0.92), path: String) async {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let limit: CGFloat = 1400
        let padded = AnyView(view.frame(width: width).padding(pad))
        var h = height ?? NSHostingView(rootView: padded).fittingSize.height
        var scale: CGFloat = 1
        if h > limit { scale = limit / h; h = limit }
        let w = (width + pad * 2) * scale
        let root = padded.scaleEffect(scale, anchor: .topLeading).frame(width: w, height: h, alignment: .topLeading)
            .background(background)
        let win = DarkWindow.make(title: "Preview", size: NSSize(width: w, height: h), content: root)
        win.setFrameOrigin(NSPoint(x: 0, y: 0))
        win.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 800_000_000)
        if let v = win.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                print("wrote \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
            }
        }
        win.orderOut(nil)
        win.close()
    }
}
#endif

import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Gathers what the user is looking at. Fast, best-effort, never throws.
@MainActor
final class ContextBuilder {
    static let shared = ContextBuilder()

    struct Snapshot {
        var turnId: UUID
        var transcript: String
        var localTime: String
        var timezone: String
        var frontmostApp: String?
        var frontmostBundleId: String?
        var windowTitle: String?
        var selectedText: String?
        var focusedText: String?
        var clipboard: String?
        var imagePaths: [String]
        var gestureImagePaths: [String]
        var openCards: String?
        var sideTasks: String
        var attachments: [String] = []
    }

    /// Captured during the fn hold (gesture overlay writes here).
    var pendingGestureShots: [String] = []
    var pendingScreenshot: String?
    /// Files the user dropped or pasted into the composer.
    var pendingAttachments: [String] = []
    /// The app that was frontmost before Avo's composer took focus, and its selection at that moment.
    var previousApp: NSRunningApplication?
    private var draftAX = AXReader.Result()
    private var draftScreenshot: String?
    private var prepared = false
    private var captureAttempted = false
    private var captureDisplayID: CGDirectDisplayID?
    private var captureScreenFrame: CGRect = .zero
    private var generation = UUID()
    private var preparation: Task<Void, Never>?

    #if DEBUG
    func loadVerificationDraft(selectedText: String? = "Move the review to Thursday at 3.") {
        discardDraft()
        prepared = true
        draftAX = AXReader.Result(windowTitle: "Meeting notes", selectedText: selectedText, focusedText: nil)
        draftScreenshot = "/tmp/avo-context-fixture.jpg"
        captureAttempted = true
    }
    var verificationDraftIsEmpty: Bool { !prepared && draftAX.selectedText == nil && draftScreenshot == nil }
    #endif

    /// Freeze context before Avo takes focus. Generation ownership prevents a late capture from
    /// replacing a newer selection. AX traversal runs off the input/UI thread.
    func capturePreActivationContext() {
        preparation?.cancel()
        generation = UUID()
        let owner = generation
        prepared = true
        pendingGestureShots = []
        pendingScreenshot = nil
        draftScreenshot = nil
        draftAX = AXReader.Result()
        captureAttempted = false
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.notchScreen
        captureDisplayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        captureScreenFrame = screen.frame
        let pid = previousApp?.processIdentifier
        preparation = Task {
            let ax = await Task.detached(priority: .userInitiated) { AXReader.read(pid: pid) }.value
            guard !Task.isCancelled, generation == owner else { return }
            draftAX = ax
            draftAX.selectedText = ax.selectedText.map { String($0.prefix(3000)) }
            draftAX.focusedText = nil
            if let t = draftAX.selectedText { NotchController.shared.showSelectionChip(words: Self.wordCount(t)) }
        }
    }

    /// Cues that a request is about what is on screen. Deictic words, visual nouns, and the on-screen
    /// tasks people phrase without a noun ("reply", "summarize", "translate"). Anything else is answered
    /// without a screenshot; the model can still call look_at_screen if it turns out to need one.
    static func wantsScreen(_ text: String) -> Bool {
        let s = " " + text.lowercased().replacingOccurrences(of: "[^a-z0-9' ]", with: " ", options: .regularExpression) + " "
        let words = ["this", "that", "these", "those", "here", "screen", "page", "tab", "window", "look", "see", "image", "picture",
                     "photo", "screenshot", "highlighted", "selected", "selection", "read", "summarize", "summarise", "translate",
                     "explain", "reply", "respond", "error", "above", "below", "chart", "graph", "table", "code", "app", "site",
                     "website", "article", "document", "doc", "pdf", "slide", "email", "message", "text", "problem", "question", "answer"]
        if words.contains(where: { s.contains(" \($0) ") }) { return true }
        let phrases = ["what am i", "what's on", "whats on", "what is on", "what's this", "whats this", "who is this", "fix it", "solve it", "check it"]
        return phrases.contains { s.contains($0) }
    }

    /// Whether the current request should carry a screenshot. `hint` is the transcript so far (partial or final).
    func shouldCapture(_ hint: String?) -> Bool {
        guard Settings.shared.screenAwareness else { return false }
        if Settings.shared.alwaysScreenshot { return true }
        guard let hint, hint.rangeOfCharacter(from: .alphanumerics) != nil else { return true }   // nothing to judge by yet
        return Self.wantsScreen(hint)
    }

    /// Called on release/send, never at the start of a hold. The flight starts after pixels are saved,
    /// so Avo's capture feedback cannot appear in its own screenshot. Skipped (and left retryable) when
    /// the words so far do not refer to the screen.
    func captureAfterSpeech(hint: String? = nil, animate: Bool = true) async {
        guard prepared, !captureAttempted else { return }
        guard shouldCapture(hint) else { return }
        captureAttempted = true
        let owner = generation
        let path = await ScreenCapture.shared.captureMain(maxWidth: 1600, displayID: captureDisplayID)
        guard !Task.isCancelled, generation == owner else { return }
        draftScreenshot = path
        if let path { NotchController.shared.showScreenChip(path: path, state: .running, fly: animate && Settings.shared.animateScreenshots, from: captureScreenFrame) }
    }

    static func wordCount(_ t: String) -> Int { t.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }

    func setGestureShots(_ paths: [String]) {
        pendingGestureShots = paths
        if !paths.isEmpty {
            captureAttempted = true
        }
    }

    func discardDraft() {
        generation = UUID()
        preparation?.cancel()
        preparation = nil
        prepared = false
        captureAttempted = false
        draftAX = AXReader.Result()
        draftScreenshot = nil
        pendingGestureShots = []
        pendingScreenshot = nil
        pendingAttachments = []
    }

    func build(turnId: UUID, transcript: String) async -> Snapshot {
        if !prepared {
            if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = app }
            // Explicit attachments and marked regions may have been supplied by another entry point.
            let marks = pendingGestureShots, screenshot = pendingScreenshot
            capturePreActivationContext()
            setGestureShots(marks)
            pendingScreenshot = screenshot
        }
        let owner = generation
        await preparation?.value
        // Final say on the screenshot: the finished transcript. Capture now if the partial one was judged too early,
        // and drop an early capture the final words turned out not to need (local pixels only; no tokens spent).
        let wantsScreen = pendingScreenshot != nil || shouldCapture(transcript)
        if wantsScreen, !Task.isCancelled, owner == generation { await captureAfterSpeech(hint: transcript) }
        if !wantsScreen, draftScreenshot != nil { draftScreenshot = nil; NotchController.shared.removeChip(NotchController.screenChipId) }
        let app = previousApp
        let fmt = DateFormatter(); fmt.dateFormat = "EEEE, MMM d yyyy h:mm a"
        var snap = Snapshot(turnId: turnId, transcript: transcript, localTime: fmt.string(from: Date()),
                            timezone: TimeZone.current.identifier, frontmostApp: app?.localizedName, frontmostBundleId: app?.bundleIdentifier,
                            windowTitle: nil, selectedText: nil, focusedText: nil, clipboard: nil, imagePaths: [], gestureImagePaths: [],
                            openCards: nil, sideTasks: "")
        guard !Task.isCancelled, owner == generation else { return snap }
        snap.windowTitle = draftAX.windowTitle
        snap.selectedText = draftAX.selectedText.map { String($0.prefix(3000)) }
        snap.gestureImagePaths = Settings.shared.screenAwareness ? pendingGestureShots : []
        // A marked region already supplies the visual target; do not pay for a second full screenshot.
        if snap.gestureImagePaths.isEmpty, Settings.shared.screenAwareness, let path = pendingScreenshot ?? draftScreenshot {
            snap.imagePaths.append(path)
        }
        snap.imagePaths.append(contentsOf: snap.gestureImagePaths)
        snap.attachments = pendingAttachments
        snap.imagePaths.append(contentsOf: pendingAttachments.filter { ["png","jpg","jpeg","gif","webp","heic"].contains(($0 as NSString).pathExtension.lowercased()) })
        var seen = Set<String>()
        snap.imagePaths = snap.imagePaths.filter { seen.insert($0).inserted }
        Log.info("Context: screen=\(snap.imagePaths.count - snap.gestureImagePaths.count > snap.attachments.count ? "yes" : "no") marks=\(snap.gestureImagePaths.count) selection=\(snap.selectedText?.count ?? 0) chars")
        discardDraft()
        let model = NotchController.shared.model
        let cards = model.cards.compactMap { c -> String? in
            switch c.kind {
            case .task(let t): return "OPEN CODING TASK CARD: id=\(t.taskId) agent=\(t.agent) title=\(t.title) status=\(t.status)"
            case .reminder(let r): return "ACTIVE NOTIFICATION CARD: reminder id=\(r.reminderId) message=\(r.message)"
            case .draft(let d): return "STAGED DRAFT CARD: \(d.title)"
            default: return nil
            }
        }
        snap.openCards = cards.isEmpty ? nil : cards.joined(separator: "\n")
        snap.sideTasks = model.sideTasks.map { "- [\($0.agent)] \($0.title): \($0.state) \($0.progress)" }.joined(separator: "\n")
        return snap
    }

    /// Text block for the user message. Images are attached separately.
    /// Per-turn context (time, frontmost app, summaries, tasks) lives here — not in the
    /// instructions — so the instructions stay byte-stable and the whole prompt prefix caches.
    func render(_ c: Snapshot) -> String {
        var out = nowBlock(c) + "\n\nUser said: \(c.transcript)\n"
        if let t = c.selectedText, !t.isEmpty { out += "\nSELECTED TEXT (in \(c.frontmostApp ?? "app")):\n\(t.prefix(3000))\n" }
        if !c.attachments.isEmpty { out += "\nATTACHED FILES (user added these to the request):\n" + c.attachments.map { "- \($0)" }.joined(separator: "\n") + "\nImages among them are attached as images; other files can be read with finder_read_file.\n" }
        if !c.gestureImagePaths.isEmpty { out += "\nThe user circled/pointed at things on screen while speaking; the attached gesture-screenshot images carry the blue marks. Use them to know which item they mean.\n" }
        else if !c.imagePaths.isEmpty { out += "\n(Attached: screenshot of the current screen.)\n" }
        return out
    }

    /// Per-turn context that used to sit at the tail of the instructions.
    private func nowBlock(_ c: Snapshot) -> String {
        var lines: [String] = ["## Now"]
        lines.append("Local time: \(c.localTime) (\(c.timezone))")
        lines.append("Frontmost app: \(c.frontmostApp ?? "unknown")" + (c.windowTitle.map { " — \($0)" } ?? ""))
        if let g = Settings.shared.googleAccountEmail { lines.append("Google account connected: \(g)") } else { lines.append("Google account: not connected (Gmail/Calendar/Drive tools will return a connect card).") }
        lines.append("Spoken replies: \(Settings.shared.speakReplies ? "on" : "off")")
        if !History.shared.recentSummaries.isEmpty {
            lines.append("\n## Earlier today")
            lines.append(History.shared.recentSummaries.suffix(3).joined(separator: "\n"))
        }
        if let cards = c.openCards, !cards.isEmpty { lines.append("\n## Open cards\n" + cards) }
        if !c.sideTasks.isEmpty { lines.append("\n## Background tasks\n" + c.sideTasks) }
        return lines.joined(separator: "\n")
    }
}

/// Accessibility reads: window title, selected text, focused element text.
enum AXReader {
    struct Result { var windowTitle: String?; var selectedText: String?; var focusedText: String? }
    static func read(pid: pid_t?) -> Result {
        guard let pid, AXIsProcessTrusted() else { return Result() }
        let app = AXUIElementCreateApplication(pid)
        var r = Result()
        var win: AnyObject?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success, let w = win {
            var title: AnyObject?
            if AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success { r.windowTitle = title as? String }
        }
        var focused: AnyObject?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let f = focused {
            let el = f as! AXUIElement
            var sel: AnyObject?
            if AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &sel) == .success, let s = sel as? String, !s.isEmpty { r.selectedText = s }
        }
        return r
    }

}

/// One-shot capture of the chosen display, downscaled JPEG.
final class ScreenCapture: @unchecked Sendable {
    static let shared = ScreenCapture()

    func captureMain(maxWidth: CGFloat, excludingSelf: Bool = true, displayID: CGDirectDisplayID? = nil) async -> String? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let pointer = CGEvent(source: nil)?.location ?? .zero
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first(where: { displayID == nil && $0.frame.contains(pointer) }) ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { return nil }
            let own = content.windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingWindows: excludingSelf ? own : [])
            let cfg = SCStreamConfiguration()
            let scale = min(1, maxWidth / CGFloat(display.width))
            cfg.width = Int(CGFloat(display.width) * scale)
            cfg.height = Int(CGFloat(display.height) * scale)
            cfg.showsCursor = true
            cfg.captureResolution = .automatic
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            return save(image, name: "screen")
        } catch {
            Log.warn("Screenshot failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Writes a JPEG into the screenshots folder and returns its path.
    ///
    /// Nothing is deleted here. `Retention` owns this folder: it keeps everything until the user
    /// picks a limit in Settings → Data, which is what "keep forever" on that screen promises. A cap
    /// applied at write time contradicted it, and — because the user's own pasted and dropped images
    /// live in the same folder — quietly took attachments away mid-conversation. Composer images are
    /// named `attach-…` so the sweep can leave them alone.
    func save(_ cg: CGImage, name: String) -> String? {
        let dir = Paths.screenshotsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name)-\(UUID().uuidString).jpg")
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else { return nil }
        try? data.write(to: url)
        return url.path
    }
}

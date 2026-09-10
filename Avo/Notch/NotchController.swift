import AppKit
import SwiftUI

/// Owns the notch panel, sizes it to content, and exposes a small API the agent runtime drives.
@MainActor
final class NotchController {
    static let shared = NotchController()
    let model = NotchModel()
    /// Built on first use, not at a fixed point in launch. A `avo://` URL arrives inside AppKit's
    /// launch sequence (`_reopenWindowsAsNecessary…` → `application(_:open:)`), which runs *before*
    /// `applicationDidFinishLaunching`, so anything that assumed `install()` had already happened
    /// unwrapped nil and trapped. Every path reaches the panel through `panel`, which builds it.
    private var installedPanel: NotchPanel?
    private var host: FirstMouseHostingView<NotchRoot>?
    private var collapseTimer: Timer?
    private var screenObserver: Any?
    private var clickMonitors: [Any] = []
    private var hoverMonitors: [Any] = []
    /// Hit-tested by the mouse-moved monitor, which fires many times a second. Keeping the rect and
    /// the last answer here — off the main actor — means a plain sweep across the menu bar costs one
    /// `contains` and publishes nothing; only a change wakes the model.
    private let hoverProbe = HoverProbe()
    private var layoutWork: DispatchWorkItem?
    private var responseFlushWork: DispatchWorkItem?
    private var pendingResponseDelta = ""
    private var lastAudioPaint = CFAbsoluteTimeGetCurrent()
    private var ignoreOutsideClicksUntil = Date.distantPast

    static let expandedWidth: CGFloat = 440
    static let maxHeight: CGFloat = 560
    /// NotchShape draws its ears `topRadius` beyond the surface, so the window keeps that much slack each side.
    static let horizontalSlack: CGFloat = 14
    static let bottomSlack: CGFloat = 14

    /// Window frame policy. The panel NEVER changes width: it is always the canvas width, centred on
    /// the notch, in every state. Only its height changes: bare notch strip while collapsed, full
    /// canvas while the glass animates, glass height once settled. A top-aligned surface inside a
    /// fixed-width host has no horizontal relayout to lag behind, which is what made the glass
    /// grow in from the left whenever SwiftUI had not yet seen a wider host.
    private var motionUntil = Date.distantPast
    private var settleWork: DispatchWorkItem?
    /// Where `model.expanded` is headed (the animated value can lag behind).
    private var targetExpanded = false

    /// Glass surface frame in SwiftUI global (hosting-view, top-left origin) coordinates.
    private var surfaceFrame: CGRect = .zero
    func surfaceFrameChanged(_ f: CGRect) {
        guard f.width.isFinite, f.height.isFinite, f.width > 0, f.height > 0 else { return }
        let oldSize = surfaceFrame.size
        surfaceFrame = f
        guard model.expanded,
              abs(oldSize.width - f.width) > 0.5 || abs(oldSize.height - f.height) > 0.5 else { return }
        if Date() < motionUntil { return }                       // the canvas already holds it; settle re-lays out
        if abs(oldSize.width - f.width) > 0.5 { noteMotion(0.4); return }   // width changes are spring-animated
        scheduleLayout()
    }

    /// Largest frame the glass can animate inside, hung from the top of the notch.
    private static func canvasRect() -> NSRect {
        let n = NSScreen.notchScreen.notchRect
        let w = expandedWidth + 2 * horizontalSlack
        let h = maxHeight + bottomSlack
        return NSRect(x: n.midX - w / 2, y: n.maxY - h, width: w, height: h)
    }

    /// Collapsed: canvas width, notch height plus a thin strip. The panel ignores mouse events in
    /// this state, so the wide transparent strip never blocks the menu bar beside the notch.
    private static func collapsedFrame() -> NSRect {
        let c = canvasRect()
        let n = NSScreen.notchScreen.notchRect
        let h = n.height + 10
        return NSRect(x: c.minX, y: n.maxY - h, width: c.width, height: h)
    }

    /// Geometry is about to animate: hold the canvas for `duration`, then hug whatever the glass settled to.
    private func noteMotion(_ duration: TimeInterval) {
        motionUntil = Date().addingTimeInterval(duration)
        layoutWork?.cancel(); layoutWork = nil
        setFrame(Self.canvasRect())
        if !panel.isVisible { panel.orderFrontRegardless() }
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.settleWork = nil
            self?.layout()
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02, execute: work)
    }

    /// The bare notch plus a thin strip below it: the only clickable area while collapsed.
    static func collapsedRect() -> NSRect {
        let n = NSScreen.notchScreen.notchRect
        return NSRect(x: n.minX, y: n.maxY - n.height - 10, width: n.width, height: n.height + 10)
    }

    /// How far below the collapsed notch still counts as hovering it, so drifting under the notch
    /// on the way to clicking it already gets a reaction.
    static let hoverSlack: CGFloat = 18

    /// The clickable notch plus that slack. Purely a hover region: hit-testing still uses `collapsedRect`.
    static func hoverRect() -> NSRect {
        let r = collapsedRect()
        return NSRect(x: r.minX, y: r.minY - hoverSlack, width: r.width, height: r.height + hoverSlack)
    }

    /// Screen rect of the visible glass surface. Built from geometry we know exactly: the glass is always
    /// centred on the notch and hangs from the top of the screen; only its size comes from SwiftUI.
    var surfaceScreenRect: NSRect? {
        if !model.expanded { return Self.collapsedRect() }
        guard surfaceFrame.width > 0, surfaceFrame.height > 0 else { return nil }
        let notch = NSScreen.notchScreen.notchRect
        let w = surfaceFrame.width, h = surfaceFrame.height
        return NSRect(x: notch.midX - w / 2, y: notch.maxY - h, width: w, height: h)
    }

    /// A click delivered to another app/window folds the notch. AppKit's local/global split means
    /// clicks inside this panel never race its SwiftUI buttons, regardless of animated geometry.
    private func outsideClick() {
        guard model.expanded else { return }
        guard Date() >= ignoreOutsideClicksUntil else { return }
        if model.isChoosingAttachments || model.pendingConfirmationId != nil || model.phase == .listening || model.phase == .thinking { return }
        collapse()
    }

    /// The notch panel, created on first access. Reading this from any thread but the main actor is
    /// impossible (the class is `@MainActor`), so the build can never race itself.
    private var panel: NotchPanel {
        if let installedPanel { return installedPanel }
        let panel = NotchPanel()
        installedPanel = panel          // set before configuring: `configure` reaches `panel` again
        configure(panel)
        return panel
    }

    /// Idempotent. Called at launch so the collapsed notch is on screen immediately; also reached
    /// lazily by the first `reveal()` when a URL beats `applicationDidFinishLaunching`.
    func install() {
        _ = panel
    }

    private func configure(_ panel: NotchPanel) {
        let host = FirstMouseHostingView(rootView: NotchRoot(model: model, controller: self))
        self.host = host
        // The root must fill the host so the glass centres on the notch. With `.intrinsicContentSize`
        // the root was laid out at its own ideal size at the host origin, so the surface grew from the
        // left edge of the canvas and settled 14 pt off-centre (verified with window snapshots).
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.isCollapsed = { [weak self] in self?.model.expanded == false }
        panel.collapsedHitRect = { Self.collapsedRect() }
        panel.onCollapsedClick = { [weak self] in self?.presentComposer() }
        panel.expandedHitRect = { [weak self] in
            guard let self, self.targetExpanded else { return nil }
            return self.surfaceScreenRect?.insetBy(dx: -10, dy: -10)
        }
        panel.onOutsideClick = { [weak self] in self?.outsideClick() }
        panel.ignoresMouseEvents = true
        host.interactiveRect = { [weak self] in
            guard let self, self.model.expanded, self.surfaceFrame.width > 0 else { return nil }
            return self.surfaceFrame
        }
        installOutsideClickMonitors()
        installHoverMonitors()
        layout()
        panel.orderFrontRegardless()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout() }
        }
    }

    func uninstall() {
        for monitor in clickMonitors { NSEvent.removeMonitor(monitor) }
        clickMonitors = []
        for monitor in hoverMonitors { NSEvent.removeMonitor(monitor) }
        hoverMonitors = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        layoutWork?.cancel()
        settleWork?.cancel()
        responseFlushWork?.cancel()
        collapseTimer?.invalidate()
    }

    private func installOutsideClickMonitors() {
        guard clickMonitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self else { return }
                // Collapsed panel ignores mouse events, so a click on the notch reaches us here.
                if !self.targetExpanded, Self.collapsedRect().contains(location) { self.presentComposer() }
                else { self.outsideClick() }
            }
        }) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            Task { @MainActor in
                guard let self, event.window !== self.panel, !(event.window is NSOpenPanel) else { return }
                self.outsideClick()
            }
            return event
        }) {
            clickMonitors.append(local)
        }
    }

    /// The collapsed panel ignores mouse events, so SwiftUI `onHover` can never fire on the bare
    /// notch. A mouse-moved monitor stands in for it: the notch lifts a little and picks up a faint
    /// accent glow while the pointer is over it, so it reads as clickable before you click.
    private func installHoverMonitors() {
        guard hoverMonitors.isEmpty else { return }
        let probe = hoverProbe
        let pointerMoved: () -> Void = { [weak self] in
            let inside = probe.rect.contains(NSEvent.mouseLocation)
            guard inside != probe.inside else { return }      // publish on change only
            probe.inside = inside
            Task { @MainActor in self?.setCollapsedHover(inside) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { _ in pointerMoved() }) {
            hoverMonitors.append(global)
        }
        // Global monitors are not delivered while Avo itself is the active app, so mirror them locally.
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { event in
            pointerMoved()
            return event
        }) {
            hoverMonitors.append(local)
        }
    }

    /// Only the collapsed, idle notch reacts: listening, thinking and replying have their own visuals.
    private func setCollapsedHover(_ hovering: Bool) {
        let value = hovering && !targetExpanded
        if model.collapsedHover != value { model.collapsedHover = value }
    }

    /// Re-run the hit test against the current geometry — after a collapse the pointer may already be
    /// sitting on the notch, with no further mouse-moved event coming to tell us.
    private func refreshCollapsedHover() {
        hoverProbe.rect = Self.hoverRect()
        let inside = hoverProbe.rect.contains(NSEvent.mouseLocation)
        hoverProbe.inside = inside
        setCollapsedHover(inside)
    }

    /// Coalesce content-driven geometry changes. Streaming text can produce several SwiftUI layout
    /// passes per network packet; the AppKit window only needs the latest settled size.
    private func scheduleLayout() {
        layoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.layoutWork = nil
            self?.layout()
        }
        layoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: work)
    }

    func layout() {
        let canvas = Self.canvasRect()
        if Date() < motionUntil {
            setFrame(canvas)
        } else if !model.expanded {
            surfaceFrame = .zero
            setFrame(Self.collapsedFrame())
        } else if let r = surfaceScreenRect, r.width > 60, r.height > 60 {
            // Height only. The top edge stays exactly at the notch top (the surface is pinned to the
            // window top), and the width stays the canvas so the surface never re-centres.
            setFrame(NSRect(x: canvas.minX, y: r.minY - Self.bottomSlack, width: canvas.width, height: r.height + Self.bottomSlack))
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        refreshCollapsedHover()
    }

    private func setFrame(_ f: NSRect) {
        if panel.frame != f { panel.setFrame(f, display: true) }
    }

    // MARK: API used by runtime

    /// `keepingCards`: a confirmation/question card is waiting for this hold's answer, so cards and the
    /// streamed line stay; only the live transcript is replaced.
    func beginListening(keepingCards: Bool = false, playSound: Bool = true) {
        collapseTimer?.invalidate()
        if keepingCards {
            if !model.transcript.isEmpty { model.transcript = "" }
            if model.errorText != nil { model.errorText = nil }
        } else if targetExpanded, !model.responseText.isEmpty {
            // Holding the key while a reply is on screen continues that chat: keep the thread visible.
            clearResponse()
            model.foldTurn()
        } else {
            clearResponse()
            model.reset()
        }
        model.showComposer = false
        model.microphoneReady = false
        model.finalizingSpeech = false
        model.phase = .listening
        reveal()
        if playSound { Sounds.shared.play(.listenStart) }
    }

    /// Listening ended with nothing to send while a card waits: show the card again.
    func resumeCard() {
        collapseTimer?.invalidate()
        model.phase = .responding
        reveal()
    }

    func updateTranscript(_ text: String, level: Float) {
        if model.transcript != text { model.transcript = text }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastAudioPaint >= 1.0 / 30.0, abs(model.audioLevel - level) >= 0.025 {
            lastAudioPaint = now
            model.audioLevel = level
        }
    }

    func endListening() {
        model.finalizingSpeech = false
        Sounds.shared.play(.listenEnd)
        model.phase = .thinking
    }

    /// Re-open the notch for a turn that starts collapsed (speech the finalizer recovered).
    func presentTurn(_ text: String) {
        clearResponse()
        // Context chips (selection, screen) were shown while listening; keep them through the reset.
        let keep = model.statusChips.filter { [Self.selectionChipId, Self.screenChipId, Self.marksChipId].contains($0.id) }
        if targetExpanded, !model.responseText.isEmpty { model.foldTurn() } else { model.reset() }
        if !keep.isEmpty { model.statusChips = keep }
        model.transcript = text
        model.phase = .thinking
        reveal()
    }

    func appendResponse(_ delta: String) {
        if model.phase != .responding { model.phase = .responding }
        pendingResponseDelta += delta
        guard responseFlushWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.responseFlushWork = nil
            self?.flushResponse()
        }
        responseFlushWork = work
        // 12.5 paints/sec still reads as live streaming without reparsing Markdown for every token.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func setResponse(_ text: String) {
        responseFlushWork?.cancel()
        responseFlushWork = nil
        pendingResponseDelta = ""
        model.phase = .responding
        if model.responseText != text { model.responseText = text }
    }

    func clearResponse() {
        responseFlushWork?.cancel()
        responseFlushWork = nil
        pendingResponseDelta = ""
        if !model.responseText.isEmpty { model.responseText = "" }
    }

    private func flushResponse() {
        guard !pendingResponseDelta.isEmpty else { return }
        model.responseText += pendingResponseDelta
        pendingResponseDelta = ""
    }

    private var chipCounts: [UUID: Int] = [:]
    func status(_ label: String, icon: String, id: UUID = UUID(), state: NotchModel.StatusChip.State = .running) -> UUID {
        if let i = model.statusChips.firstIndex(where: { $0.id == id }) {
            model.statusChips[i].label = label; model.statusChips[i].state = state; model.statusChips[i].icon = icon
        } else if let i = model.statusChips.firstIndex(where: { $0.icon == icon && ($0.label == label || $0.label.hasPrefix(label + " ×")) }) {
            // Same tool again this turn: fold into one chip with a count instead of a row of duplicates.
            let n = (chipCounts[model.statusChips[i].id] ?? 1) + 1
            chipCounts[model.statusChips[i].id] = n
            model.statusChips[i].label = "\(label) ×\(n)"; model.statusChips[i].state = .running
            return model.statusChips[i].id
        } else {
            withAnimation(Theme.springQuick) { model.statusChips.append(.init(id: id, icon: icon, label: label, state: state)) }
        }
        return id
    }

    /// Context chips: what is riding along with the request. Fixed ids so they update in place.
    static let selectionChipId = UUID(), screenChipId = UUID(), marksChipId = UUID()
    func showSelectionChip(words: Int) {
        _ = status("Selection · \(words) word\(words == 1 ? "" : "s")", icon: "text.cursor", id: Self.selectionChipId, state: .done)
    }
    func showContextChips(selectionWords: Int?, screenPath: String?, marks: Int, markPath: String? = nil) {
        if let w = selectionWords { showSelectionChip(words: w) }
        if let p = screenPath { showScreenChip(path: p, state: .done, fly: false, from: .zero) }
        if marks > 0 { _ = status("Marked \(marks == 1 ? "region" : "regions")", icon: markPath.map { "img:\($0)" } ?? "pencil.tip.crop.circle", id: Self.screenChipId, state: .done) }
    }
    /// Screen chip with a thumbnail of the capture. With `fly`, the screenshot animates from the screen
    /// into this chip (falls back to the notch when the chip has no frame yet).
    func showScreenChip(path: String, state: NotchModel.StatusChip.State, fly: Bool, from screenFrame: CGRect) {
        _ = status("Screen", icon: "img:\(path)", id: Self.screenChipId, state: state)
        guard fly else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 70_000_000)   // one layout pass so the chip has a frame
            ScreenCaptureFlight.shared.present(path: path, from: screenFrame, to: self?.chipScreenCenter(Self.screenChipId))
        }
    }
    func removeChip(_ id: UUID) {
        withAnimation(Theme.springQuick) { model.statusChips.removeAll { $0.id == id } }
    }
    var chipFrames: [UUID: CGRect] = [:]
    /// Screen-space center of a chip, from the SwiftUI (top-left) frame reported by ChipsRow.
    func chipScreenCenter(_ id: UUID) -> CGPoint? {
        guard targetExpanded, let r = chipFrames[id], let cv = panel.contentView else { return nil }
        let ak = NSRect(x: r.minX, y: cv.bounds.height - r.maxY, width: r.width, height: r.height)
        let sr = panel.convertToScreen(ak)
        return CGPoint(x: sr.midX, y: sr.midY)
    }

    func finishStatus(_ id: UUID, ok: Bool) {
        if let i = model.statusChips.firstIndex(where: { $0.id == id }) {
            withAnimation(Theme.springQuick) { model.statusChips[i].state = ok ? .done : .failed }
        }
    }

    func present(_ card: CardKind, id: UUID = UUID()) {
        if model.expanded { noteMotion(0.5) }
        withAnimation(Theme.springCard) { model.cards.append(AnyCard(id: id, kind: card)) }
        if case .confirmation = card { model.pendingConfirmationId = id; Sounds.shared.play(.card) }
        else if case .question = card { model.pendingConfirmationId = id; Sounds.shared.play(.card) }
        reveal()
        collapseTimer?.invalidate()
    }

    func update(_ id: UUID, _ card: CardKind) {
        if let i = model.cards.firstIndex(where: { $0.id == id }) {
            model.cards[i] = AnyCard(id: id, kind: card)
        }
    }

    func dismissCard(_ id: UUID) {
        if model.expanded, model.cards.contains(where: { $0.id == id }) { noteMotion(0.4) }
        withAnimation(Theme.springClose) { model.cards.removeAll { $0.id == id } }
        if model.pendingConfirmationId == id { model.pendingConfirmationId = nil }
    }

    func done(autoCollapseAfter seconds: TimeInterval = 0) {
        responseFlushWork?.cancel()
        responseFlushWork = nil
        flushResponse()
        model.phase = .done
        Sounds.shared.play(.done)
        if seconds > 0 { scheduleCollapse(after: seconds) }
    }

    func fail(_ message: String) {
        responseFlushWork?.cancel()
        responseFlushWork = nil
        flushResponse()
        model.phase = .error
        model.errorText = message
        Sounds.shared.play(.error)
    }

    func scheduleCollapse(after seconds: TimeInterval) {
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.model.hoverPinned || self.model.pendingConfirmationId != nil || self.model.showComposer { self.scheduleCollapse(after: 4); return }
                self.collapse()
            }
        }
    }

    func collapse() {
        collapseTimer?.invalidate()
        if model.showComposer {
            ContextBuilder.shared.discardDraft()
        }
        guard targetExpanded else { model.showComposer = false; return }
        targetExpanded = false
        panel.ignoresMouseEvents = true
        // Hold the canvas while the glass springs shut; the window drops to the bare notch at settle.
        noteMotion(0.4)
        withAnimation(Theme.springClose) {
            model.expanded = false
            model.showComposer = false
        }
        // Keep the last exchange around so a click on the notch brings it back. Transient state goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, !self.model.expanded else { return }
            self.model.statusChips = []; self.model.errorText = nil; self.model.speaking = false
            if self.model.phase == .listening || self.model.phase == .thinking { self.model.reset() }
        }
    }

    func presentIdleHint() {
        guard !model.expanded else { return }
        clearResponse()
        model.reset()
        model.phase = .idle
        reveal()
    }

    func presentComposer() {
        collapseTimer?.invalidate()
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            ContextBuilder.shared.previousApp = front
        }
        ContextBuilder.shared.capturePreActivationContext()
        if model.phase == .listening || model.phase == .thinking { model.reset() }
        model.showComposer = true
        reveal()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens the glass with a quick spring inside the fixed canvas; the window hugs it once settled.
    func reveal() {
        // A request that starts while the last reply is still on screen continues that chat.
        AgentRuntime.shared.requestBeganWhileOpen = targetExpanded
        if !targetExpanded {
            targetExpanded = true
            if model.collapsedHover { model.collapsedHover = false }
            surfaceFrame = .zero
            panel.ignoresMouseEvents = false
            noteMotion(0.5)
            withAnimation(Theme.springOpen) { model.expanded = true }
        }
        // Ignore the click/key activation event that caused the surface to open.
        ignoreOutsideClicksUntil = Date().addingTimeInterval(0.25)
    }

    /// Debug: render the panel's content view to a PNG (works without Screen Recording permission).
    /// Asks the window server which window sits under points around the notch (no events posted).
    #if DEBUG
    func debugHitTest() {
        let screen = NSScreen.notchScreen
        let n = screen.notchRect
        Log.info("HitTest: panel #\(panel.windowNumber) frame=\(panel.frame) notch=\(n) expanded=\(model.expanded) ignores=\(panel.ignoresMouseEvents) visible=\(panel.isVisible) alpha=\(panel.alphaValue)")
        for dy in [-2.0, -6.0, -12.0, -20.0, -40.0] {
            let p = NSPoint(x: n.midX, y: n.minY + dy)   // below the notch (Cocoa coords, y up)
            let num = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
            Log.info("HitTest: point \(p) → window #\(num)\(num == panel.windowNumber ? " (Avo)" : "")")
        }
        if let v = panel.contentView { Log.info("HitTest: contentView frame=\(v.frame) hit(top-center)=\(String(describing: v.hitTest(NSPoint(x: v.bounds.midX, y: v.bounds.maxY - 3))))") }
    }

    func debugSnapshot(to path: String) {
        var i = 0
        for w in NSApp.windows where w.isVisible {
            guard let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let p = i == 0 ? path : path.replacingOccurrences(of: ".png", with: "-\(i).png")
            if let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: p)) }
            Log.info("Snapshot \(w.title.isEmpty ? "notch" : w.title) → \(p)")
            i += 1
        }
    }
    #endif
}


/// Hosting view that takes the first click even when the panel is not key. The small transparent
/// inset around the fitted surface remains click-through.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var interactiveRect: (() -> CGRect?)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        // SwiftUI global coordinates are top-left based inside the host; NSView hit testing is
        // bottom-left based. Compare in the same coordinate system or the top half rejects clicks.
        let swiftUIPoint = NSPoint(x: point.x, y: bounds.height - point.y)
        if let r = interactiveRect?(), !r.insetBy(dx: -10, dy: -10).contains(swiftUIPoint) { return nil }
        return super.hitTest(point)
    }
}


/// Pointer state shared with the mouse-moved monitors. Deliberately outside the main actor: the
/// monitor closures run on the main thread but are not actor-isolated, and hopping onto the actor
/// for every mouse move just to answer "still over the notch?" is exactly the cost worth avoiding.
final class HoverProbe: @unchecked Sendable {
    var rect: NSRect = .zero
    var inside = false
}

import AppKit
import SwiftUI
import Combine

/// The "side notch": a slim tab docked to the right screen edge that slides out into a panel listing
/// long-running coding tasks (Working / Done) and the last few exchanges (Earlier).
///
/// Nothing polls. The panel re-derives its rows from `CodingTaskStore.shared.tasks` whenever
/// `NotchController.shared.model.sideTasks` changes (the store publishes that on every task update),
/// from explicit `upsert(_:)` calls, and from `History.shared` (observed by the view).
@MainActor
final class SideNotch {
    static let shared = SideNotch()

    static let panelWidth: CGFloat = 300
    static let maxHeight: CGFloat = 560
    /// The panel is a real sidebar even when its content is sparse.
    static let minPanelHeight: CGFloat = 420
    static let tabWidth: CGFloat = 6
    static let tabHeight: CGFloat = 96
    /// Extra invisible slack to the left of the tab so the hover target is not a 6 px sliver.
    static let tabHitSlack: CGFloat = 12
    static let cornerRadius: CGFloat = 18
    static let holdAfterFinish: TimeInterval = 12

    let model = SideNotchModel()
    private var panel: SideNotchPanel!
    private var host: FirstMouseHostingView<SideNotchRoot>!
    private var tasksCancellable: AnyCancellable?
    private var sizeCancellable: AnyCancellable?
    private var screenObserver: Any?
    private var retractTimer: Timer?
    private var frameTimer: Timer?
    private var keyMonitors: [Any] = []
    private var contentHeight: CGFloat = 0
    private var installed = false
    /// Window frame is wide while the panel is out or still animating; independent of `model.out`
    /// so the debounced layout pass never clips a spring mid-flight.
    private var wideFrame = false
    /// Last known (status, needsInput) per task id, used to detect transitions.
    private var lastStates: [String: String] = [:]
    private var didInitialSync = false

    private let enabledKey = "sideNotchEnabled"
    private(set) var enabled: Bool = UserDefaults.standard.object(forKey: "sideNotchEnabled") as? Bool ?? true

    // MARK: install / enable

    func install() {
        guard !installed else { return }
        installed = true
        panel = SideNotchPanel()
        host = FirstMouseHostingView(rootView: SideNotchRoot(model: model, controller: self))
        host.sizingOptions = []
        panel.contentView = host
        layout()
        if enabled { panel.orderFrontRegardless() }

        // The store's init mirrors persisted tasks into sideTasks; touch it before subscribing so the
        // first sink already sees a populated list.
        _ = CodingTaskStore.shared
        tasksCancellable = NotchController.shared.model.$sideTasks
            .sink { [weak self] _ in
                // Deliver after the property has been set (Published emits on willSet).
                Task { @MainActor in self?.refresh() }
            }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout() }
        }
        sizeCancellable = model.objectWillChange
            .debounce(for: .milliseconds(8), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.layout() } }
        refresh()
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: enabledKey)
        guard installed else { return }
        if on { layout(); panel.orderFrontRegardless() }
        else { retract(immediately: true); panel.orderOut(nil) }
    }

    /// Explicit hook for CodingTaskStore: refresh rows immediately for this task.
    func upsert(_ task: CodingTask) {
        guard installed else { return }
        refresh()
    }

    // MARK: derive rows

    /// Rebuilds Working / Done from the store and reacts to state transitions.
    private func refresh() {
        let all = CodingTaskStore.shared.tasks
        let working = all.filter { $0.isActive }.sorted { $0.createdAt > $1.createdAt }
        let dismissed = CodingTaskStore.shared.dismissed
        let cutoff = Date().addingTimeInterval(-3 * 86400)
        let done = all.filter { !$0.isActive && !dismissed.contains($0.id) && ($0.finishedAt ?? $0.createdAt) > cutoff }
            .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
        let doneRows = Array(done.prefix(6))

        // Transitions: new task, finished, needs input, input answered.
        var shouldSlideOut = false
        var chime: Sounds.Cue?
        var states: [String: String] = [:]
        for t in all {
            let key = t.status
            states[t.id] = key
            guard didInitialSync else { continue }
            let prev = lastStates[t.id]
            guard prev != key else { continue }
            switch t.status {
            case "queued", "running":
                if prev == nil { shouldSlideOut = true }               // dispatched
                else if prev == "waiting" { shouldSlideOut = true }    // answered; timer decides retract
            case "waiting":
                shouldSlideOut = true
            case "done":
                shouldSlideOut = true; chime = .done
            case "failed":
                shouldSlideOut = true; chime = .error
            case "stopped":
                shouldSlideOut = true
            default: break
            }
        }
        lastStates = states
        didInitialSync = true

        if model.working != working { model.working = working }
        if model.done != doneRows { model.done = doneRows }
        if let id = model.expandedId, !working.contains(where: { $0.id == id }), !doneRows.contains(where: { $0.id == id }) { model.expandedId = nil }

        // Completion sounds live here (removed from CodingTaskStore so they never play twice).
        if let c = chime { Sounds.shared.play(c) }
        if shouldSlideOut, enabled { slideOut(hold: Self.holdAfterFinish) }
        else if model.out { scheduleRetractCheck(after: 0.2) }
    }

    // MARK: slide in / out

    /// Bring the panel out. It stays while hovered, while any task needs input, and for `hold` seconds.
    func slideOut(hold: TimeInterval) {
        guard enabled else { return }
        model.holdUntil = max(model.holdUntil ?? .distantPast, Date().addingTimeInterval(hold))
        frameTimer?.invalidate()
        if !model.out {
            // Frame first, then the content springs in from the edge.
            wideFrame = true
            layout()
            withAnimation(Theme.springOpen) { model.out = true }
            installKeyMonitor()
        }
        scheduleRetractCheck(after: hold + 0.05)
    }

    func retract(immediately: Bool = false) {
        retractTimer?.invalidate()
        removeKeyMonitor()
        model.holdUntil = nil
        model.expandedId = nil
        guard model.out else { layout(); return }
        if immediately {
            model.out = false
            wideFrame = false
            layout()
            return
        }
        withAnimation(Theme.springClose) { model.out = false }
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.model.out else { return }
                self.wideFrame = false
                self.layout()
            }
        }
    }

    /// Hover state from the view. Hover keeps the panel out; leaving schedules a retract.
    /// Opening from hover holds for a moment so the window-resize tracking churn can never
    /// fire a spurious exit and snap the panel shut before the cursor re-registers.
    func setHovered(_ h: Bool) {
        model.hovered = h
        if h {
            retractTimer?.invalidate()
            if !model.out { slideOut(hold: 1.2) }
        } else {
            scheduleRetractCheck(after: 0.6)
        }
    }

    private func scheduleRetractCheck(after s: TimeInterval) {
        retractTimer?.invalidate()
        retractTimer = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.retractIfIdle() }
        }
    }

    private func retractIfIdle() {
        guard model.out else { return }
        if model.hovered { return }
        if model.working.contains(where: { $0.status == "waiting" }) { return }   // stays until answered
        if let until = model.holdUntil, until > Date() {
            scheduleRetractCheck(after: until.timeIntervalSinceNow + 0.05)
            return
        }
        retract()
    }

    // MARK: actions from the view

    func stop(_ id: String) { _ = CodingTaskStore.shared.stop(id) }
    func openFolder(_ id: String) { CodingTaskStore.shared.openInFinder(id) }
    func dismiss(_ id: String) {
        withAnimation(Theme.springClose) { model.done.removeAll { $0.id == id } }
        CodingTaskStore.shared.dismiss(id)
    }
    func clearDone() {
        withAnimation(Theme.springClose) { model.done = [] }
        CodingTaskStore.shared.dismissAllDone()
    }
    /// Bring the task's card into the main notch and tuck the sidebar away.
    func open(_ id: String) {
        CodingTaskStore.shared.present(id)
        retract()
    }
    func reply(_ id: String, _ text: String) {
        if let err = CodingTaskStore.shared.reply(id, text: text) { Log.error("Side reply: \(err)") }
    }
    func switchModel(_ id: String, model: String?, effort: String?) {
        CodingTaskStore.shared.switchModel(id, model: model, effort: effort)
    }
    func toggleExpanded(_ id: String) {
        withAnimation(Theme.springQuick) { model.expandedId = model.expandedId == id ? nil : id }
    }

    /// Re-open the main notch with a whole past chat: earlier turns stacked above the last one.
    func reopen(_ chat: History.Chat) {
        let nc = NotchController.shared
        nc.clearResponse()
        nc.model.reset()
        var turns = chat.exchanges
        guard let last = turns.popLast() else { return }
        nc.model.priorTurns = turns.map { .init(id: UUID(), user: $0.user, reply: $0.reply) }
        nc.model.transcript = last.user
        nc.model.responseText = last.reply
        nc.model.phase = .done
        nc.reveal()
        // Opening a chat means "continue this one": it becomes the current chat.
        AgentRuntime.shared.resume(chat: chat)
        retract()
    }

    // MARK: geometry

    /// Idle: a 6 × 96 tab (plus hover slack) at the right edge. Out: 300 wide, sidebar-tall.
    func layout() {
        guard installed else { return }
        let screen = NSScreen.notchScreen
        let vf = screen.visibleFrame
        let topY = vf.maxY - vf.height * 0.2
        let frame: NSRect
        if wideFrame {
            let h = min(Self.maxHeight, max(Self.minPanelHeight, contentHeight))
            frame = NSRect(x: screen.frame.maxX - Self.panelWidth, y: topY - h, width: Self.panelWidth, height: h)
        } else {
            let w = Self.tabWidth + Self.tabHitSlack
            frame = NSRect(x: screen.frame.maxX - w, y: topY - Self.tabHeight, width: w, height: Self.tabHeight)
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if enabled, !panel.isVisible { panel.orderFrontRegardless() }
    }

    func contentHeightChanged(_ h: CGFloat) {
        guard abs(h - contentHeight) > 0.5 else { return }
        contentHeight = h
        if model.out { layout() }
    }

    // MARK: Esc

    private func installKeyMonitor() {
        guard keyMonitors.isEmpty else { return }
        let handle: (NSEvent) -> Void = { [weak self] e in
            guard e.keyCode == 53 else { return }
            Task { @MainActor in
                guard let self, self.model.out, self.model.hovered else { return }
                self.retract()
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handle) { keyMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in handle(e); return e }) { keyMonitors.append(l) }
    }

    private func removeKeyMonitor() {
        for m in keyMonitors { NSEvent.removeMonitor(m) }
        keyMonitors = []
    }
}

/// View state for the side notch.
@MainActor
final class SideNotchModel: ObservableObject {
    @Published var out = false
    @Published var hovered = false
    @Published var working: [CodingTask] = []
    @Published var done: [CodingTask] = []
    @Published var expandedId: String?
    @Published var tab: Tab = .tasks
    enum Tab { case tasks, chats }
    var holdUntil: Date?

    var needsInput: Bool { working.contains { $0.status == "waiting" } }
    var anyRunning: Bool { !working.isEmpty }

}

/// Borderless, non-activating floating panel for the side notch.
final class SideNotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        appearance = NSAppearance(named: .darkAqua)
    }
    override var canBecomeKey: Bool { true }     // same as NotchPanel: clicks on buttons land without activating Avo
    override var canBecomeMain: Bool { false }
}

extension CodingTask: Equatable {
    static func == (a: CodingTask, b: CodingTask) -> Bool {
        a.id == b.id && a.status == b.status && a.activity == b.activity && a.result == b.result
            && a.title == b.title && a.finishedAt == b.finishedAt
    }
}

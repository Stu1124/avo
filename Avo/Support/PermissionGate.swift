import AVFoundation
import AppKit
import CoreLocation
import EventKit
import Foundation
import Speech

/// One shared CLLocationManager so polling the status does not allocate a manager every second,
/// and so the authorization prompt has an owner that outlives the call that triggered it.
/// Both callers (the permissions poller and the gate) are on the main actor.
enum LocationPrompt {
    nonisolated(unsafe) private static let manager = CLLocationManager()
    static var status: CLAuthorizationStatus { manager.authorizationStatus }
    static func request() { manager.requestWhenInUseAuthorization() }
}

/// Just-in-time permission checks for tools.
///
/// Onboarding asks for the four permissions the hold-to-talk loop cannot work without. Everything
/// else is asked for the first time a tool actually needs it: `ensure` returns immediately when the
/// permission is already granted, shows the system prompt when macOS still offers one, and otherwise
/// puts a card in the notch explaining what is missing with a button that opens the right pane.
///
/// It never blocks forever — every wait is bounded, including the framework callbacks, which have no
/// timeout of their own — and it never throws.
@MainActor
enum PermissionGate {
    /// How long to wait for the user to answer a system prompt before giving up and showing the card.
    private static let promptTimeout: TimeInterval = 60

    /// Screen Recording's answer only takes effect after a relaunch, so there is nothing to wait for
    /// beyond the moment the prompt appears. Poll briefly, then let the card carry the instruction.
    private static let preflightTimeout: TimeInterval = 6

    /// How often the bounded waits re-read the status. Slow enough to cost nothing, fast enough that
    /// answering a prompt feels immediate.
    private static let pollInterval: UInt64 = 400_000_000

    /// The card currently on screen for a permission, so a model that calls three reminder tools in a
    /// row does not stack three identical cards.
    ///
    /// Keyed by kind, valued by the card's id — not a bare set. A card can leave the screen without
    /// going through its own `onAnswer`: `NotchModel.reset()` (every talk-key press) and `foldTurn()`
    /// both clear `cards` wholesale. A kind therefore only counts as shown while its id is still in
    /// the notch; once the card is gone the next denied gate puts a fresh one up.
    private static var shown: [PermissionKind: UUID] = [:]

    /// Kinds whose system prompt has already been asked for in this process. macOS shows each of
    /// these once and silently returns the stored answer afterwards, so asking twice would only add
    /// a dead wait in front of the card.
    private static var requested: Set<PermissionKind> = []

    /// True when the tool may proceed. False means a card is on screen and the tool should return
    /// `.fail(_, guidance: PermissionGate.guidance(kind))`.
    static func ensure(_ kind: PermissionKind) async -> Bool {
        if kind.status() == .granted { clear(kind); return true }

        if let granted = await requestSystemPrompt(kind), granted { clear(kind); return true }
        if kind.status() == .granted { clear(kind); return true }

        present(kind)
        return false
    }

    /// The permission named the way a sentence wants it. "Reminders access" reads right;
    /// "Full Disk Access access" does not.
    nonisolated private static func phrase(_ kind: PermissionKind) -> String {
        kind.title.hasSuffix("Access") ? kind.title : "\(kind.title) access"
    }

    /// What the model should tell the user after a denied gate.
    nonisolated static func guidance(_ kind: PermissionKind) -> String {
        "Avo does not have \(phrase(kind)). Tell the user to grant it in System Settings → Privacy & Security → \(kind.title) — the card on screen has a button — then ask again."
    }

    /// The failure a gated tool returns, so every tool words this the same way.
    nonisolated static func failure(_ kind: PermissionKind) -> ToolResult {
        .fail("\(phrase(kind)) is not granted.", guidance: guidance(kind))
    }

    // MARK: system prompts

    /// Shows the macOS prompt where the framework has one. Returns nil when there is no in-app prompt
    /// or one has already been shown this session, otherwise the user's answer.
    ///
    /// Every branch is bounded. The framework request calls (AVFoundation, Speech, EventKit) hand
    /// back a callback that never fires until the user answers, so they are started detached and the
    /// answer is read off the status instead — which is what `waitForGrant` polls.
    private static func requestSystemPrompt(_ kind: PermissionKind) async -> Bool? {
        switch kind {
        case .microphone:
            guard startPrompt(kind, { _ = await AVCaptureDevice.requestAccess(for: .audio) }) else { return nil }
            return await waitForGrant(kind, timeout: promptTimeout)
        case .speechRecognition:
            guard startPrompt(kind, { SFSpeechRecognizer.requestAuthorization { _ in } }) else { return nil }
            return await waitForGrant(kind, timeout: promptTimeout)
        case .reminders:
            guard startPrompt(kind, { let store = EKEventStore(); _ = try? await store.requestFullAccessToReminders() }) else { return nil }
            return await waitForGrant(kind, timeout: promptTimeout)
        case .calendars:
            guard startPrompt(kind, { let store = EKEventStore(); _ = try? await store.requestFullAccessToEvents() }) else { return nil }
            return await waitForGrant(kind, timeout: promptTimeout)
        case .location:
            guard startPrompt(kind, { await MainActor.run { LocationPrompt.request() } }) else { return nil }
            return await waitForGrant(kind, timeout: promptTimeout)
        case .screenRecording:
            // `CGPreflightScreenCaptureAccess` answers yes/no only — it never reports "not determined",
            // so the status can never ask for this prompt on its own. Ask CoreGraphics once per
            // session instead: on a fresh install it puts the system dialog up, and after that it
            // returns the stored answer immediately and the card below does the explaining.
            guard requested.insert(kind).inserted else { return nil }
            Log.info("Permission gate: asking macOS for \(kind.title)")
            if Permissions.requestScreen() { return true }
            return await waitForGrant(kind, timeout: preflightTimeout)
        // Full Disk Access has no prompt at all; Input Monitoring, Accessibility and Automation are
        // handled by the onboarding rows and by macOS itself.
        case .fullDiskAccess, .inputMonitoring, .accessibility, .automation:
            return nil
        }
    }

    /// Fires a framework permission request once per session, without waiting on its callback.
    /// Returns false when there is nothing to ask — already asked, or already answered.
    private static func startPrompt(_ kind: PermissionKind, _ request: @escaping @Sendable () async -> Void) -> Bool {
        guard kind.status() == .notDetermined, requested.insert(kind).inserted else { return false }
        Log.info("Permission gate: asking macOS for \(kind.title)")
        Task.detached(priority: .userInitiated) { await request() }
        return true
    }

    /// Polls until the permission is granted, the user answers with a no, or the timeout expires.
    /// Never spins the CPU and never runs past `timeout`.
    ///
    /// A `.denied` reading only ends the wait for kinds that have a real `.notDetermined` state.
    /// Screen Recording reads `.denied` from the first call to the last, so for it only a grant or
    /// the deadline ends the loop.
    private static func waitForGrant(_ kind: PermissionKind, timeout: TimeInterval) async -> Bool {
        let deniedIsAnswer = kind != .screenRecording
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch kind.status() {
            case .granted: return true
            case .notDetermined: break
            default: if deniedIsAnswer { return false }
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }
        return kind.status() == .granted
    }

    // MARK: the card

    /// True while this kind's card is still in the notch. Anything that emptied `cards` — a new talk
    /// key press, a folded turn, the user answering — makes this false and lets the next denied gate
    /// present again.
    private static func isOnScreen(_ kind: PermissionKind) -> Bool {
        guard let id = shown[kind] else { return false }
        if NotchController.shared.model.cards.contains(where: { $0.id == id }) { return true }
        shown[kind] = nil
        return false
    }

    /// Forgets this kind's card and takes it off screen if it is still up — a permission that has
    /// just been granted should not leave a card asking for it.
    private static func clear(_ kind: PermissionKind) {
        guard let id = shown.removeValue(forKey: kind) else { return }
        NotchController.shared.dismissCard(id)
    }

    private static func present(_ kind: PermissionKind) {
        guard !isOnScreen(kind) else { return }
        let id = UUID()
        shown[kind] = id
        let card = QuestionCard(
            id: id,
            icon: kind.icon,
            title: "Avo needs \(phrase(kind)) to do that.",
            body: "\(kind.detail) Nothing happens until you allow it.",
            options: ["Open Settings", "Not now"],
            allowFreeText: false,
            onAnswer: { answer in
                Task { @MainActor in
                    if answer == "Open Settings" { Permissions.open(kind.pane) }
                    shown[kind] = nil
                    NotchController.shared.dismissCard(id)
                }
            })
        NotchController.shared.present(.question(card), id: id)
        Log.warn("Permission gate blocked: \(kind.title)")
    }
}

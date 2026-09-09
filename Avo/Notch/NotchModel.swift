import SwiftUI
import Combine

/// Everything the notch renders. Single source of truth, mutated on the main actor.
@MainActor
final class NotchModel: ObservableObject {
    enum Phase: Equatable { case idle, listening, thinking, responding, done, error }

    @Published var phase: Phase = .idle
    @Published var expanded = false
    @Published var transcript = ""            // live user speech (partial)
    @Published var responseText = ""          // streamed assistant text
    @Published var priorTurns: [PriorTurn] = [] // earlier turns of the same chat, shown above the current one
    @Published var statusChips: [StatusChip] = []
    @Published var cards: [AnyCard] = []
    @Published var composerText = ""
    @Published var attachments: [String] = []
    @Published var showComposer = false
    @Published var isChoosingAttachments = false
    @Published var finalizingSpeech = false
    @Published var microphoneReady = false
    @Published var audioLevel: Float = 0
    @Published var errorText: String?
    @Published var hoverPinned = false
    @Published var speaking = false
    @Published var deepMode = false
    @Published var sideTasks: [SideTask] = []
    @Published var pendingConfirmationId: UUID?

    struct PriorTurn: Identifiable, Equatable { let id: UUID; var user: String; var reply: String }

    struct StatusChip: Identifiable, Equatable {
        enum State: Equatable { case running, done, failed }
        let id: UUID
        var icon: String          // SF symbol or "app:<bundle id>"
        var label: String
        var state: State
    }

    struct SideTask: Identifiable, Equatable {
        let id: String
        var title: String
        var subtitle: String
        var agent: String
        var progress: String
        var state: String        // queued, running, waiting, done, failed
        var needsInput: Bool
    }

    /// Composer alone (no reply, no cards): render a small bar instead of the full panel.
    var isCompactComposer: Bool { showComposer && responseText.isEmpty && cards.isEmpty && transcript.isEmpty && (phase == .idle || phase == .done) }

    /// Keep the chat on screen: the turn that is showing becomes a prior turn, and the live slots clear
    /// for the next one. Used when a new request starts while the notch is already open.
    func foldTurn() {
        if !transcript.isEmpty, !responseText.isEmpty { priorTurns.append(.init(id: UUID(), user: transcript, reply: responseText)) }
        if priorTurns.count > 12 { priorTurns.removeFirst(priorTurns.count - 12) }
        finalizingSpeech = false
        microphoneReady = false
        if phase != .idle { phase = .idle }
        transcript = ""; responseText = ""
        if !statusChips.isEmpty { statusChips = [] }
        if !cards.isEmpty { cards = [] }
        if errorText != nil { errorText = nil }
        if pendingConfirmationId != nil { pendingConfirmationId = nil }
        if speaking { speaking = false }
    }

    func reset() {
        finalizingSpeech = false
        microphoneReady = false
        if phase != .idle { phase = .idle }
        if !transcript.isEmpty { transcript = "" }
        if !responseText.isEmpty { responseText = "" }
        if !priorTurns.isEmpty { priorTurns = [] }
        if !statusChips.isEmpty { statusChips = [] }
        if !cards.isEmpty { cards = [] }
        if errorText != nil { errorText = nil }
        if pendingConfirmationId != nil { pendingConfirmationId = nil }
        if speaking { speaking = false }
    }
}

/// Type-erased card so heterogeneous cards live in one array.
struct AnyCard: Identifiable, Equatable {
    let id: UUID
    let kind: CardKind
    static func == (a: AnyCard, b: AnyCard) -> Bool { a.id == b.id && a.kind.revision == b.kind.revision }
}

enum CardKind {
    case confirmation(ConfirmationCard)
    case glance(GlanceCard)
    case draft(DraftCard)
    case files(FilesCard)
    case task(TaskCard)
    case reminder(ReminderCard)
    case question(QuestionCard)
    var revision: Int {
        switch self {
        case .confirmation(let c): return c.revision
        case .glance(let g): return g.revision
        case .draft(let d): return d.revision
        case .files(let f): return f.revision
        case .task(let t): return t.revision
        case .reminder(let r): return r.revision
        case .question(let q): return q.revision
        }
    }
}

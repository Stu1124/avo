import Foundation
import AppKit

struct CodingTask: Codable, Identifiable {
    var id: String                    // 6-char
    var agent: String                 // "claude" | "codex"
    var title: String
    var project: String               // absolute path
    var instruction: String
    var mode: String                  // "code" | "read_only"
    var status: String                // queued, running, waiting, done, failed, stopped
    var sessionId: String?            // Claude session_id / Codex thread id
    var activity: [String] = []       // last 40 lines
    var result: String?
    var createdAt: Date
    var finishedAt: Date?
    var model: String?
    var effort: String?

    var agentLabel: String { agent == "codex" ? "Codex" : "Claude Code" }
    var projectName: String { (project as NSString).lastPathComponent }
    var isActive: Bool { status == "queued" || status == "running" || status == "waiting" }
}

/// Persistent task list + live sessions; mirrors state into the notch (side tasks + TaskCard).
@MainActor
final class CodingTaskStore {
    static let shared = CodingTaskStore()
    private(set) var tasks: [CodingTask] = []
    private var sessions: [String: CodingAgentSession] = [:]
    private var cardIds: [String: UUID] = [:]
    private var saveWork: DispatchWorkItem?
    private let notch = NotchController.shared

    private init() { load() }

    // MARK: persistence

    private func load() {
        guard let data = try? Data(contentsOf: Paths.tasksDB) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if var t = try? dec.decode([CodingTask].self, from: data) {
            // Nothing survives a relaunch as running.
            for i in t.indices where t[i].isActive {
                t[i].status = "stopped"; t[i].finishedAt = t[i].finishedAt ?? Date()
                if t[i].result == nil { t[i].result = "Avo restarted while this task was running." }
            }
            tasks = t
        }
        syncSideTasks()
    }

    private func save() {
        saveWork?.cancel()
        let snapshot = tasks
        let w = DispatchWorkItem {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
            try? FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
            if let d = try? enc.encode(snapshot) { try? d.write(to: Paths.tasksDB, options: .atomic) }
        }
        saveWork = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    // MARK: lookup

    func task(_ id: String) -> CodingTask? { tasks.first { $0.id == id } }

    /// id, id prefix, or title / project-name substring; newest first.
    func find(_ ref: String) -> CodingTask? {
        let r = ref.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !r.isEmpty else { return nil }
        let sorted = tasks.sorted { $0.createdAt > $1.createdAt }
        if let t = sorted.first(where: { $0.id.lowercased() == r }) { return t }
        if let t = sorted.first(where: { $0.id.lowercased().hasPrefix(r) }) { return t }
        if let t = sorted.first(where: { $0.title.lowercased().contains(r) || $0.projectName.lowercased().contains(r) }) { return t }
        return nil
    }

    // MARK: create / start

    @discardableResult
    func dispatch(agent: String, title: String, project: String, instruction: String, mode: String, model: String?, effort: String?) -> CodingTask {
        var id = Self.shortId()
        while tasks.contains(where: { $0.id == id }) { id = Self.shortId() }
        var t = CodingTask(id: id, agent: agent, title: title, project: project, instruction: instruction, mode: mode,
                           status: "queued", createdAt: Date(), model: model, effort: effort)
        tasks.insert(t, at: 0)
        if tasks.count > 60 { tasks = Array(tasks.prefix(60)) }
        ProjectResolver.remember(project)

        let session: CodingAgentSession = agent == "codex"
            ? CodexSession(project: project, mode: mode, model: model, effort: effort)
            : ClaudeCodeSession(project: project, mode: mode, model: model, effort: effort)
        attach(session, to: id)
        do {
            try session.start(message: instruction)
            t.status = "running"
            t.activity = ["Starting \(t.agentLabel) in \(t.projectName)"]
            update(t)
            showCard(t, present: true)
        } catch {
            t.status = "failed"; t.finishedAt = Date(); t.result = error.localizedDescription
            update(t)
            showCard(t, present: true)
            // Completion/failure sounds are played by SideNotch (one place, never twice).
        }
        save()
        return t
    }

    private func attach(_ session: CodingAgentSession, to id: String) {
        sessions[id] = session
        session.onEvent = { [weak self] ev in
            Task { @MainActor in self?.handle(ev, for: id) }
        }
    }

    private func handle(_ ev: CodingSessionEvent, for id: String) {
        guard var t = task(id) else { return }
        switch ev {
        case .sessionId(let s):
            t.sessionId = s
        case .activity(let line):
            let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !l.isEmpty, t.activity.last != l else { return }
            t.activity.append(l)
            if t.activity.count > 40 { t.activity.removeFirst(t.activity.count - 40) }
            if t.status == "queued" { t.status = "running" }
        case .waiting(let w):
            if t.isActive { t.status = w ? "waiting" : "running" }
        case .turnDone(let text, let ok):
            if t.status == "stopped" { break }
            t.status = ok ? "done" : "failed"
            t.finishedAt = Date()
            t.result = String(text.prefix(4000))
            t.activity.append(ok ? "Finished" : "Failed")
            update(t)
            showCard(t, present: true)      // final result stays in the main notch
            notch.reveal()
            // Chime is played by SideNotch when it sees the done/failed transition.
            notch.scheduleCollapse(after: 25)
            save()
            return
        case .exited(let code):
            if t.isActive {
                t.status = "failed"; t.finishedAt = Date()
                t.result = t.result ?? "\(t.agentLabel) exited (code \(code))."
                update(t); showCard(t, present: true); save()   // sound: SideNotch
                return
            }
        }
        update(t)
        // Progress goes to the side notch; the main-notch card is only refreshed in place if it is
        // still on screen from the dispatch moment (showCard never presents here).
        showCard(t, present: false)
        SideNotch.shared.upsert(t)
    }

    // MARK: actions

    /// Follow-up into the same session (relaunches with resume if the process is gone).
    func reply(_ id: String, text: String) -> String? {
        guard var t = task(id) else { return "No task \(id)" }
        if t.status == "stopped" && sessions[id] == nil && t.sessionId == nil { return "Task \(id) was stopped and has no session to resume." }
        var session = sessions[id]
        if session == nil {
            let s: CodingAgentSession = t.agent == "codex"
                ? CodexSession(project: t.project, mode: t.mode, model: t.model, effort: t.effort, resume: t.sessionId)
                : ClaudeCodeSession(project: t.project, mode: t.mode, model: t.model, effort: t.effort, resume: t.sessionId)
            attach(s, to: id)
            session = s
            do { try s.start(message: text) } catch { sessions[id] = nil; return error.localizedDescription }
        } else {
            session?.send(text)
        }
        t.status = "running"; t.finishedAt = nil; t.result = nil
        t.activity.append("You: \(text.prefix(100))")
        if t.activity.count > 40 { t.activity.removeFirst(t.activity.count - 40) }
        update(t)
        showCard(t, present: true)
        save()
        return nil
    }

    /// Change the model/effort for a task. A live session is relaunched on the same session id so the
    /// agent keeps its context; a finished task just uses the new model on its next follow-up.
    func switchModel(_ id: String, model: String?, effort: String?) {
        guard var t = task(id) else { return }
        t.model = model; t.effort = effort
        let label = ModelCatalog.label(for: model, agent: t.agent) + (effort.map { " · \(ModelCatalog.effortLabel($0))" } ?? "")
        let wasActive = t.isActive && sessions[id] != nil
        update(t); save()
        if wasActive, let s = sessions[id] {
            s.onEvent = nil          // this exit is ours, not a failure
            s.stop()
            sessions[id] = nil
            t.activity.append("Switched to \(label)")
            update(t)
            _ = reply(id, text: "You were switched to \(label). Continue the task exactly where you left off.")
        } else {
            t.activity.append("Next run: \(label)")
            update(t); save()
            showCard(t, present: false)
        }
        SideNotch.shared.upsert(t)
    }

    /// Put (or bring back) the task's card in the main notch.
    func present(_ id: String) {
        guard let t = task(id) else { return }
        showCard(t, present: true)
        notch.reveal()
    }

    private static let dismissedKey = "codingTasks.dismissed"
    private(set) var dismissed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "codingTasks.dismissed") ?? [])
    func dismiss(_ id: String) {
        dismissed.insert(id)
        UserDefaults.standard.set(Array(dismissed), forKey: Self.dismissedKey)
        // `task(id)` is nil once the row has been pruned, and `tasks` can be empty by then.
        if let t = task(id) ?? tasks.first { SideNotch.shared.upsert(t) }
    }
    func dismissAllDone() {
        for t in tasks where !t.isActive { dismissed.insert(t.id) }
        UserDefaults.standard.set(Array(dismissed), forKey: Self.dismissedKey)
        if let t = tasks.first { SideNotch.shared.upsert(t) }
    }

    func stop(_ id: String) -> Bool {
        guard var t = task(id) else { return false }
        sessions[id]?.stop()
        guard t.isActive else { return true }
        t.status = "stopped"; t.finishedAt = Date()
        t.activity.append("Stopped")
        if t.result == nil { t.result = "Stopped by user." }
        update(t)
        showCard(t, present: false)
        save()
        return true
    }

    func openInFinder(_ id: String) {
        guard let t = task(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: t.project)])
    }

    // MARK: notch sync

    private func update(_ t: CodingTask) {
        if let i = tasks.firstIndex(where: { $0.id == t.id }) { tasks[i] = t }
        syncSideTasks()
    }

    private func syncSideTasks() {
        let cutoff = Date().addingTimeInterval(-10 * 60)
        let visible = tasks.filter { $0.isActive || ($0.finishedAt ?? .distantPast) > cutoff }
        let side = visible.map { t in
            NotchModel.SideTask(id: t.id, title: t.title, subtitle: t.projectName, agent: t.agentLabel,
                                progress: t.activity.last ?? "", state: t.status == "stopped" ? "failed" : t.status,
                                needsInput: t.status == "waiting")
        }
        if notch.model.sideTasks != side { notch.model.sideTasks = side }
    }

    private func card(for t: CodingTask) -> TaskCard {
        let status: String
        switch t.status {
        case "queued": status = "running"
        case "stopped": status = "failed"
        default: status = t.status
        }
        var c = TaskCard(id: cardIds[t.id] ?? UUID(), taskId: t.id, agent: t.agentLabel, title: t.title, status: status,
                         lines: Array(t.activity.suffix(30)), result: t.result.map { Self.trimResult($0) },
                         project: (t.project as NSString).abbreviatingWithTildeInPath, startedAt: t.createdAt, finishedAt: t.finishedAt,
                         agentKey: t.agent, model: t.model, effort: t.effort)
        c.revision = t.activity.count + (t.result?.count ?? 0) + status.hashValue % 1000
        c.onAction = { [weak self] action in
            Task { @MainActor in
                switch action {
                case "stop": _ = self?.stop(t.id)
                case "open": self?.openInFinder(t.id)
                case let a where a.hasPrefix("reply:"):
                    if let err = self?.reply(t.id, text: String(a.dropFirst(6))) { Log.error("Task reply: \(err)") }
                case let a where a.hasPrefix("model:"):
                    let parts = a.dropFirst(6).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                    self?.switchModel(t.id, model: parts.first.flatMap { $0.isEmpty ? nil : $0 }, effort: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
                default: break
                }
            }
        }
        return c
    }

    /// Update the card if it is on screen; present it when `present` or when it is missing and the task just finished.
    private func showCard(_ t: CodingTask, present: Bool) {
        let c = card(for: t)
        let id = c.id
        cardIds[t.id] = id
        if notch.model.cards.contains(where: { $0.id == id }) {
            notch.update(id, .task(c))
        } else if present {
            notch.present(.task(c), id: id)
        }
    }

    static func trimResult(_ s: String) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        let kept = lines.prefix(8).joined(separator: "\n")
        return kept.count < s.count ? kept + "\n…" : kept
    }

    private static func shortId() -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<6).map { _ in chars.randomElement()! })
    }
}

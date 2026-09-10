import Foundation

/// Events a coding-agent session reports back to the task store.
enum CodingSessionEvent {
    case sessionId(String)                       // Claude session_id / Codex thread id
    case activity(String)                        // one short line for the card
    case waiting(Bool)                           // true while a permission / question card is up
    case turnDone(text: String, ok: Bool)        // one turn finished (result text)
    case exited(code: Int32)                     // process ended
}

protocol CodingAgentSession: AnyObject {
    var onEvent: ((CodingSessionEvent) -> Void)? { get set }
    func start(message: String) throws
    func send(_ message: String)
    func stop()
}

/// Headless Claude Code over `--input-format stream-json --output-format stream-json --permission-prompt-tool stdio`.
final class ClaudeCodeSession: CodingAgentSession, @unchecked Sendable {
    let project: String
    let mode: String                 // "code" | "read_only"
    let model: String?
    let effort: String?
    let addDirs: [String]
    private(set) var sessionId: String?

    var onEvent: ((CodingSessionEvent) -> Void)?

    private var runner: ProcessRunner?
    private let q = DispatchQueue(label: "avo.claude.session")
    private var turnActive = false
    private var queued: [String] = []
    private var allowAlways: Set<String> = []
    private var idleTimer: DispatchWorkItem?
    private var stopping = false

    init(project: String, mode: String, model: String? = nil, effort: String? = nil, resume sessionId: String? = nil, addDirs: [String] = []) {
        self.project = project
        self.mode = mode
        self.model = model
        self.effort = effort
        self.addDirs = addDirs
        self.sessionId = sessionId
    }

    static var binary: String? { ProcessRunner.resolve("claude") }

    // MARK: lifecycle

    func start(message: String) throws {
        try launch()
        q.async { self.sendNow(message) }
    }

    func send(_ message: String) {
        q.async {
            if self.runner?.isRunning != true {
                do { try self.launch() } catch { self.onEvent?(.activity("Could not relaunch Claude Code: \(error.localizedDescription)")); return }
            }
            if self.turnActive {
                if self.queued.count >= 20 { self.queued.removeFirst() }
                self.queued.append(message); self.onEvent?(.activity("Queued follow-up"))
            }
            else { self.sendNow(message) }
        }
    }

    func stop() {
        q.async {
            self.stopping = true
            self.queued.removeAll()
            self.runner?.stop(grace: 5)
        }
    }

    private func launch() throws {
        guard let bin = Self.binary else { throw NSError(domain: "Avo", code: 1, userInfo: [NSLocalizedDescriptionKey: "claude CLI not found in PATH"]) }
        let auto = MainActorBox.autoApprove()
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--permission-prompt-tool", "stdio", "--verbose"]
        let permMode: String
        if mode == "read_only" { permMode = "plan" }
        else if auto { permMode = "bypassPermissions" }
        else { permMode = "acceptEdits" }
        args += ["--permission-mode", permMode]
        if permMode == "bypassPermissions" { args.append("--dangerously-skip-permissions") }
        args += ["--append-system-prompt", Self.contract]
        if let s = sessionId { args += ["--resume", s] }
        for d in addDirs { args += ["--add-dir", d] }
        if let m = model, !m.isEmpty { args += ["--model", m] }
        if let e = effort, !e.isEmpty { args += ["--effort", Self.normalizeEffort(e)] }

        let r = ProcessRunner(executable: bin, arguments: args, cwd: project)
        r.onLine = { [weak self] line in self?.q.async { self?.handle(line: line) } }
        r.onStderr = { s in
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { Log.warn("claude stderr: \(t.prefix(300))") }
        }
        r.onExit = { [weak self] code in
            guard let self else { return }
            self.q.async {
                let wasActive = self.turnActive
                self.turnActive = false
                if wasActive && !self.stopping { self.onEvent?(.turnDone(text: "Claude Code exited (code \(code)) before finishing.", ok: false)) }
                self.onEvent?(.exited(code: code))
            }
        }
        try r.start()
        runner = r
        stopping = false
    }

    private func sendNow(_ text: String) {
        turnActive = true
        idleTimer?.cancel()
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]]
        runner?.write(JSON.stringify(msg))
    }

    /// After a turn, keep the process for follow-ups for 10 min, then close stdin so it exits (resume with --resume later).
    private func scheduleIdleExit() {
        idleTimer?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.turnActive else { return }
            self.runner?.closeStdin()
        }
        idleTimer = w
        q.asyncAfter(deadline: .now() + 600, execute: w)
    }

    // MARK: stdout parsing

    private func handle(line: String) {
        guard line.hasPrefix("{"), let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
        let type = obj["type"] as? String ?? ""
        switch type {
        case "system":
            if let sid = obj["session_id"] as? String, !sid.isEmpty, sid != sessionId { sessionId = sid; onEvent?(.sessionId(sid)) }
            if obj["subtype"] as? String == "init", let m = obj["model"] as? String { onEvent?(.activity("Claude Code ready (\(m))")) }
        case "assistant":
            guard let msg = obj["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return }
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String { let l = Self.firstLine(t); if !l.isEmpty { onEvent?(.activity(l)) } }
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    onEvent?(.activity(Self.describe(tool: name, input: input)))
                default: break
                }
            }
        case "result":
            let isError = obj["is_error"] as? Bool ?? false
            var text = obj["result"] as? String ?? ""
            if text.isEmpty, let errs = obj["errors"] as? [String] { text = errs.joined(separator: "\n") }
            if text.isEmpty { text = isError ? "Claude Code reported an error." : "Done." }
            if let sid = obj["session_id"] as? String, sid != sessionId { sessionId = sid; onEvent?(.sessionId(sid)) }
            turnActive = false
            onEvent?(.turnDone(text: text, ok: !isError))
            if !queued.isEmpty { sendNow(queued.removeFirst()) } else { scheduleIdleExit() }
        case "control_request":
            handleControlRequest(obj)
        default:
            break   // user (tool results), rate_limit_event, stream_event, control_cancel_request
        }
    }

    // MARK: permissions

    private func handleControlRequest(_ obj: [String: Any]) {
        guard let requestId = obj["request_id"] as? String, let req = obj["request"] as? [String: Any] else { return }
        guard req["subtype"] as? String == "can_use_tool" else { return }
        let tool = req["tool_name"] as? String ?? "tool"
        let input = req["input"] as? [String: Any] ?? [:]

        if tool == "AskUserQuestion" {
            onEvent?(.waiting(true))
            Task { @MainActor [weak self] in
                guard let self else { return }
                var answers: [String: String] = [:]
                let questions = input["questions"] as? [[String: Any]] ?? []
                for qd in questions {
                    let question = qd["question"] as? String ?? "Claude Code has a question"
                    let header = qd["header"] as? String
                    let opts = (qd["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                    let descs = (qd["options"] as? [[String: Any]] ?? []).compactMap { o -> String? in
                        guard let l = o["label"] as? String, let d = o["description"] as? String, !d.isEmpty else { return nil }
                        return "\(l): \(d)"
                    }
                    var body = header.map { "\($0)\n" } ?? ""
                    body += descs.prefix(4).joined(separator: "\n")
                    let a = await AgentRuntime.shared.ask(icon: CodingTools.claudeIcon, title: question, body: body.trimmingCharacters(in: .whitespacesAndNewlines), options: opts, freeText: true)
                    answers[question] = a
                }
                if questions.isEmpty {
                    let a = await AgentRuntime.shared.ask(icon: CodingTools.claudeIcon, title: "Claude Code has a question", body: JSON.stringify(input).prefix(300).description, options: [], freeText: true)
                    answers["answer"] = a
                }
                var updated = input
                updated["answers"] = answers
                self.q.async {
                    self.onEvent?(.waiting(false))
                    self.respond(requestId: requestId, behavior: "allow", updatedInput: updated, permissions: nil, message: nil)
                }
            }
            return
        }

        if allowAlways.contains(tool) {
            respond(requestId: requestId, behavior: "allow", updatedInput: input, permissions: nil, message: nil)
            return
        }

        let (title, body) = Self.permissionPrompt(tool: tool, input: input, reason: req["decision_reason"] as? String)
        onEvent?(.waiting(true))
        onEvent?(.activity("Waiting for permission: \(tool)"))
        Task { @MainActor [weak self] in
            guard let self else { return }
            let a = await AgentRuntime.shared.ask(icon: CodingTools.claudeIcon, title: title, body: body, options: ["Allow", "Always allow", "Deny"], freeText: false)
            let lower = a.lowercased()
            self.q.async {
                self.onEvent?(.waiting(false))
                if lower.hasPrefix("always") {
                    self.allowAlways.insert(tool)
                    let rules: [[String: Any]] = [["type": "addRules", "rules": [["toolName": tool]], "behavior": "allow", "destination": "session"]]
                    self.respond(requestId: requestId, behavior: "allow", updatedInput: input, permissions: rules, message: nil)
                } else if lower.hasPrefix("allow") || lower == "yes" || lower == "ok" || lower == "okay" || lower == "sure" || lower == "go ahead" {
                    self.respond(requestId: requestId, behavior: "allow", updatedInput: input, permissions: nil, message: nil)
                } else {
                    self.respond(requestId: requestId, behavior: "deny", updatedInput: nil, permissions: nil, message: "User denied")
                }
            }
        }
    }

    private func respond(requestId: String, behavior: String, updatedInput: [String: Any]?, permissions: [[String: Any]]?, message: String?) {
        var inner: [String: Any] = ["behavior": behavior]
        if let u = updatedInput { inner["updatedInput"] = u }
        if let p = permissions { inner["updatedPermissions"] = p }
        if let m = message { inner["message"] = m }
        let msg: [String: Any] = ["type": "control_response",
                                  "response": ["subtype": "success", "request_id": requestId, "response": inner]]
        runner?.write(JSON.stringify(msg))
    }

    // MARK: helpers

    static func firstLine(_ t: String) -> String {
        let l = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return String(l.prefix(140))
    }

    static func describe(tool: String, input: [String: Any]) -> String {
        func base(_ k: String) -> String { (((input[k] as? String) ?? "") as NSString).lastPathComponent }
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Editing \(base("file_path").isEmpty ? base("notebook_path") : base("file_path"))"
        case "Read": return "Reading \(base("file_path"))"
        case "Bash": return "Running: \((input["command"] as? String ?? "").prefix(100))"
        case "Grep": return "Searching for \((input["pattern"] as? String ?? "").prefix(60))"
        case "Glob": return "Finding \((input["pattern"] as? String ?? "").prefix(60))"
        case "Agent", "Task": return "Subagent: \((input["description"] as? String ?? "").prefix(80))"
        case "WebFetch": return "Fetching \((input["url"] as? String ?? "").prefix(80))"
        case "WebSearch": return "Searching web: \((input["query"] as? String ?? "").prefix(60))"
        case "TodoWrite": return "Updating plan"
        case "AskUserQuestion": return "Asking you a question"
        case "ExitPlanMode": return "Plan ready"
        default: return tool.replacingOccurrences(of: "mcp__", with: "")
        }
    }

    static func permissionPrompt(tool: String, input: [String: Any], reason: String?) -> (String, String) {
        var body = ""
        switch tool {
        case "Bash": body = input["command"] as? String ?? ""
        case "Edit", "Write", "MultiEdit": body = (input["file_path"] as? String ?? "")
        default: body = String(JSON.stringify(input).prefix(240))
        }
        if let r = reason, !r.isEmpty { body += "\n\(r)" }
        let verb: String
        switch tool {
        case "Bash": verb = "run a command"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": verb = "edit \(((input["file_path"] as? String ?? "") as NSString).lastPathComponent)"
        case "WebFetch", "WebSearch": verb = "use the web"
        default: verb = "use \(tool)"
        }
        return ("Claude Code wants to \(verb)", String(body.prefix(400)))
    }

    static func normalizeEffort(_ e: String) -> String {
        switch e.lowercased() {
        case "minimal", "lowest": return "low"
        case "maximum", "max": return "max"
        case "xhigh", "extra high", "very high": return "xhigh"
        default: return e.lowercased()
        }
    }

    /// Appended system prompt: what Avo needs from a headless session, chiefly how long-running processes must be started.
    static let contract = """
    You are running as a headless, non-interactive Claude Code session started by Avo, a voice assistant on this Mac. Avo closes this session as soon as you return your final result, and anything still running inside your shell dies with it.

    Rules for long-running processes (dev servers, watchers, tunnels, daemons):
    - Start them detached with nohup from a normal foreground shell call, e.g. `nohup <cmd> > /tmp/<name>.log 2>&1 & echo $!`. Never use run_in_background for them and never put a timeout on that call.
    - Before starting a listener, check whether one already exists on that port (`lsof -i :<port>`) and reuse it instead of starting a duplicate.
    - Record the PID, the log path and the exact stop command in your final message.
    - Verify after launch (curl the port or tail the log) before reporting success.

    Your final message is shown to the user on a small card in the notch and may be read aloud. Lead with the outcome in 1-3 short lines, then what changed and how it was verified. No preamble, no headings.
    """
}

/// Tiny bridge to read main-actor settings from session queues.
enum MainActorBox {
    static func autoApprove() -> Bool {
        if Thread.isMainThread { return MainActor.assumeIsolated { Settings.shared.codingAutoApprove } }
        return UserDefaults.standard.bool(forKey: "codingAutoApprove")
    }
}

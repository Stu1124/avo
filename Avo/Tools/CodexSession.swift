import Foundation

/// Codex via `codex app-server` (newline-delimited JSON-RPC over stdio, no "jsonrpc" field),
/// falling back to `codex exec --json` when the app-server does not answer `initialize` within 8 s.
final class CodexSession: CodingAgentSession, @unchecked Sendable {
    let project: String
    let mode: String                 // "code" | "read_only"
    let model: String?
    let effort: String?
    private(set) var threadId: String?

    var onEvent: ((CodingSessionEvent) -> Void)?

    private enum Transport { case appServer, exec }
    private var transport: Transport = .appServer
    private var runner: ProcessRunner?
    private let q = DispatchQueue(label: "avo.codex.session")
    private var nextId = 1
    private var pending: [Int: (Any?, [String: Any]?) -> Void] = [:]
    private var initialized = false
    private var turnActive = false
    private var queued: [String] = []
    private var agentText = ""
    private var lastAgentMessage = ""
    private var lastActivityEmit = Date.distantPast
    private var acceptForSessionCommands = false
    private var acceptForSessionFiles = false
    private var stopping = false
    private var execFirstMessage: String?

    init(project: String, mode: String, model: String? = nil, effort: String? = nil, resume threadId: String? = nil) {
        self.project = project
        self.mode = mode
        self.model = model
        self.effort = effort
        self.threadId = threadId
    }

    static var binary: String? { ProcessRunner.resolve("codex") }

    private var sandbox: String { mode == "read_only" ? "read-only" : "workspace-write" }
    private var approvalPolicy: String { MainActorBox.autoApprove() ? "never" : "unlessTrusted" }

    // MARK: lifecycle

    func start(message: String) throws {
        guard let bin = Self.binary else { throw NSError(domain: "Avo", code: 1, userInfo: [NSLocalizedDescriptionKey: "codex CLI not found in PATH"]) }
        try launchAppServer(bin)
        q.async { self.beginTurn(message) }
    }

    func send(_ message: String) {
        q.async {
            if self.turnActive { self.queued.append(message); self.onEvent?(.activity("Queued follow-up")); return }
            switch self.transport {
            case .appServer:
                if self.runner?.isRunning != true {
                    guard let bin = Self.binary else { return }
                    do { try self.launchAppServer(bin) } catch { self.onEvent?(.activity("Could not relaunch Codex")); return }
                    self.initialized = false
                }
                self.beginTurn(message)
            case .exec:
                self.runExec(message)
            }
        }
    }

    func stop() {
        q.async {
            self.stopping = true
            self.queued.removeAll()
            if self.transport == .appServer, let t = self.threadId, self.turnActive, let r = self.runner, r.isRunning {
                self.request("turn/interrupt", ["threadId": t]) { _, _ in }
                self.q.asyncAfter(deadline: .now() + 2) { self.runner?.stop(grace: 3) }
            } else {
                self.runner?.stop(grace: 5)
            }
        }
    }

    // MARK: app-server transport

    private func launchAppServer(_ bin: String) throws {
        let r = ProcessRunner(executable: bin, arguments: ["app-server"], cwd: project)
        r.onLine = { [weak self] line in self?.q.async { self?.handleAppServer(line: line) } }
        r.onStderr = { s in
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !t.contains("failed to load skill"), !t.contains("rmcp::") { Log.warn("codex stderr: \(t.prefix(300))") }
        }
        r.onExit = { [weak self] code in
            guard let self else { return }
            self.q.async {
                guard self.transport == .appServer else { return }
                let wasActive = self.turnActive
                self.turnActive = false
                self.pending.removeAll()
                if wasActive && !self.stopping { self.onEvent?(.turnDone(text: "Codex exited (code \(code)) before finishing.", ok: false)) }
                self.onEvent?(.exited(code: code))
            }
        }
        try r.start()
        runner = r
        stopping = false
        transport = .appServer
    }

    /// initialize → initialized → thread/start|resume → turn/start. Falls back to exec if initialize is silent for 8 s.
    private func beginTurn(_ message: String) {
        turnActive = true
        agentText = ""; lastAgentMessage = ""
        if initialized { startTurn(message); return }
        var answered = false
        request("initialize", ["clientInfo": ["name": "avo", "version": "1.0"], "capabilities": ["experimentalApi": true]]) { [weak self] result, error in
            guard let self else { return }
            answered = true
            if let e = error { self.onEvent?(.activity("Codex init error: \(e["message"] as? String ?? "?")")); self.fallbackToExec(message); return }
            self.initialized = true
            self.notify("initialized", [:])
            self.openThread { ok in
                if ok { self.startTurn(message) } else { self.fallbackToExec(message) }
            }
        }
        q.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !answered else { return }
            Log.warn("codex app-server: no initialize response in 8 s, falling back to exec")
            self.fallbackToExec(message)
        }
    }

    private func openThread(_ done: @escaping (Bool) -> Void) {
        if let t = threadId {
            request("thread/resume", ["threadId": t, "cwd": project, "approvalPolicy": approvalPolicy, "sandbox": sandbox]) { [weak self] result, error in
                guard let self else { return }
                if error == nil, let r = result as? [String: Any], let th = r["thread"] as? [String: Any], let id = th["id"] as? String {
                    self.threadId = id; done(true)
                } else {
                    // Thread unknown to this server: start fresh.
                    self.threadId = nil
                    self.openThread(done)
                }
            }
            return
        }
        var params: [String: Any] = ["cwd": project, "approvalPolicy": approvalPolicy, "sandbox": sandbox]
        if let m = model, !m.isEmpty { params["model"] = m }
        if let e = effort, !e.isEmpty { params["reasoningEffort"] = Self.normalizeEffort(e) }
        request("thread/start", params) { [weak self] result, error in
            guard let self else { return }
            if let r = result as? [String: Any], let th = r["thread"] as? [String: Any], let id = th["id"] as? String {
                self.threadId = id
                self.onEvent?(.sessionId(id))
                if let m = r["model"] as? String { self.onEvent?(.activity("Codex ready (\(m))")) }
                done(true)
            } else {
                self.onEvent?(.activity("Codex thread/start failed: \(error?["message"] as? String ?? "unknown")"))
                done(false)
            }
        }
    }

    private func startTurn(_ message: String) {
        guard let t = threadId else { turnActive = false; return }
        request("turn/start", ["threadId": t, "input": [["type": "text", "text": message]]]) { [weak self] _, error in
            guard let self, let e = error else { return }
            self.turnActive = false
            self.onEvent?(.turnDone(text: "Codex could not start the turn: \(e["message"] as? String ?? "?")", ok: false))
        }
    }

    private func request(_ method: String, _ params: [String: Any], _ cb: @escaping (Any?, [String: Any]?) -> Void) {
        let id = nextId; nextId += 1
        pending[id] = cb
        runner?.write(JSON.stringify(["id": id, "method": method, "params": params]))
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        runner?.write(JSON.stringify(["method": method, "params": params]))
    }

    private func respond(id: Any, result: [String: Any]) {
        runner?.write(JSON.stringify(["id": id, "result": result]))
    }

    private func respondError(id: Any, message: String) {
        runner?.write(JSON.stringify(["id": id, "error": ["code": -32000, "message": message]]))
    }

    private func handleAppServer(line: String) {
        guard line.hasPrefix("{"), let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
        let method = obj["method"] as? String
        if let id = obj["id"] {
            if let m = method {
                handleServerRequest(id: id, method: m, params: obj["params"] as? [String: Any] ?? [:])
            } else if let n = (id as? NSNumber)?.intValue, let cb = pending.removeValue(forKey: n) {
                cb(obj["result"], obj["error"] as? [String: Any])
            }
            return
        }
        guard let m = method else { return }
        let p = obj["params"] as? [String: Any] ?? [:]
        switch m {
        case "item/agentMessage/delta":
            if let d = p["delta"] as? String { agentText += d; emitAgentLine() }
        case "item/started":
            if let item = p["item"] as? [String: Any] { describe(item: item, started: true) }
        case "item/completed":
            if let item = p["item"] as? [String: Any] {
                if item["type"] as? String == "agentMessage", let t = item["text"] as? String, !t.isEmpty { lastAgentMessage = t }
                else { describe(item: item, started: false) }
            }
        case "item/commandExecution/outputDelta", "item/fileChange/outputDelta", "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
            break
        case "item/plan/delta":
            break
        case "turn/started":
            turnActive = true
        case "turn/completed":
            let turn = p["turn"] as? [String: Any] ?? [:]
            let status = turn["status"] as? String ?? "completed"
            turnActive = false
            let text = lastAgentMessage.isEmpty ? agentText.trimmingCharacters(in: .whitespacesAndNewlines) : lastAgentMessage
            switch status {
            case "failed":
                let msg = (turn["error"] as? [String: Any])?["message"] as? String ?? "Codex turn failed."
                onEvent?(.turnDone(text: text.isEmpty ? msg : "\(text)\n\(msg)", ok: false))
            case "interrupted":
                onEvent?(.turnDone(text: text.isEmpty ? "Stopped." : text, ok: false))
            default:
                onEvent?(.turnDone(text: text.isEmpty ? "Done." : text, ok: true))
            }
            if !queued.isEmpty { let next = queued.removeFirst(); agentText = ""; lastAgentMessage = ""; turnActive = true; startTurn(next) }
        case "approval/requested":
            // Older protocol variant: notification + approval/decide.
            let approvalId = p["approvalId"] as? String ?? ""
            let action = p["action"] as? String ?? JSON.stringify(p["context"] ?? [:])
            askApproval(title: "Codex wants to \(action.prefix(80))", body: String(JSON.stringify(p["context"] ?? [:]).prefix(300))) { [weak self] decision in
                self?.notify("approval/decide", ["approvalId": approvalId, "approved": decision != .deny])
            }
        case "error":
            if let msg = p["message"] as? String ?? (p["error"] as? [String: Any])?["message"] as? String { onEvent?(.activity("Codex: \(msg.prefix(120))")) }
        case "thread/status/changed", "thread/tokenUsage/updated", "mcpServer/startupStatus/updated", "remoteControl/status/changed", "thread/started", "turn/diff/updated", "turn/plan/updated":
            break
        default:
            break
        }
    }

    private func describe(item: [String: Any], started: Bool) {
        switch item["type"] as? String {
        case "commandExecution":
            if started, let c = item["command"] as? String { onEvent?(.activity("Running: \(c.prefix(100))")) }
        case "fileChange":
            let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { ($0["path"] as? String).map { ($0 as NSString).lastPathComponent } }
            if !paths.isEmpty { onEvent?(.activity("Editing \(paths.prefix(3).joined(separator: ", "))")) }
        case "webSearch":
            if started { onEvent?(.activity("Searching web")) }
        case "mcpToolCall":
            if started { onEvent?(.activity("Calling \((item["tool"] as? String ?? "tool").prefix(60))")) }
        default: break
        }
    }

    private func emitAgentLine() {
        guard Date().timeIntervalSince(lastActivityEmit) > 0.8 else { return }
        let l = ClaudeCodeSession.firstLine(String(agentText.split(separator: "\n").last ?? ""))
        if !l.isEmpty { lastActivityEmit = Date(); onEvent?(.activity(l)) }
    }

    // MARK: approvals (server → client requests, answered by id)

    private enum Decision { case allow, allowSession, deny }

    private func handleServerRequest(id: Any, method: String, params p: [String: Any]) {
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            let cmd = p["command"] as? String ?? (p["command"] as? [String])?.joined(separator: " ") ?? ""
            if acceptForSessionCommands { respond(id: id, result: ["decision": method == "execCommandApproval" ? "approved" : "accept"]); return }
            var body = cmd
            if let r = p["reason"] as? String, !r.isEmpty { body += "\n\(r)" }
            askApproval(title: "Codex wants to run a command", body: String(body.prefix(400))) { [weak self] d in
                guard let self else { return }
                let legacy = method == "execCommandApproval"
                switch d {
                case .allow: self.respond(id: id, result: ["decision": legacy ? "approved" : "accept"])
                case .allowSession: self.acceptForSessionCommands = true; self.respond(id: id, result: ["decision": legacy ? "approved_for_session" : "acceptForSession"])
                case .deny: self.respond(id: id, result: ["decision": legacy ? "denied" : "decline"])
                }
            }
        case "item/fileChange/requestApproval", "applyPatchApproval":
            let legacy = method == "applyPatchApproval"
            if acceptForSessionFiles { respond(id: id, result: ["decision": legacy ? "approved" : "accept"]); return }
            var body = ""
            if let changes = p["fileChanges"] as? [String: Any] { body = changes.keys.map { ($0 as NSString).lastPathComponent }.prefix(5).joined(separator: ", ") }
            if let r = p["reason"] as? String, !r.isEmpty { body += (body.isEmpty ? "" : "\n") + r }
            if let g = p["grantRoot"] as? String { body += (body.isEmpty ? "" : "\n") + "Write access under \(ProjectResolver.abbreviated(g))" }
            askApproval(title: "Codex wants to edit files", body: String(body.prefix(400))) { [weak self] d in
                guard let self else { return }
                switch d {
                case .allow: self.respond(id: id, result: ["decision": legacy ? "approved" : "accept"])
                case .allowSession: self.acceptForSessionFiles = true; self.respond(id: id, result: ["decision": legacy ? "approved_for_session" : "acceptForSession"])
                case .deny: self.respond(id: id, result: ["decision": legacy ? "denied" : "decline"])
                }
            }
        case "item/permissions/requestApproval":
            let reason = p["reason"] as? String ?? "extra permissions"
            askApproval(title: "Codex asks for more access", body: String(reason.prefix(400))) { [weak self] d in
                guard let self else { return }
                if d == .deny { self.respondError(id: id, message: "User denied") }
                else { self.respond(id: id, result: ["permissions": p["permissions"] ?? [:], "scope": d == .allowSession ? "session" : "turn"]) }
            }
        case "item/tool/requestUserInput":
            let questions = p["questions"] as? [[String: Any]] ?? []
            onEvent?(.waiting(true))
            Task { @MainActor [weak self] in
                guard let self else { return }
                var answers: [String: Any] = [:]
                for qd in questions {
                    let qid = qd["id"] as? String ?? UUID().uuidString
                    let question = qd["question"] as? String ?? "Codex has a question"
                    let header = qd["header"] as? String ?? ""
                    let opts = (qd["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                    let a = await AgentRuntime.shared.ask(icon: CodingTools.codexIcon, title: question, body: header, options: opts, freeText: true)
                    answers[qid] = ["answers": [a]]
                }
                self.q.async {
                    self.onEvent?(.waiting(false))
                    self.respond(id: id, result: ["answers": answers])
                }
            }
        case "mcpServer/elicitation/request":
            respond(id: id, result: ["action": "decline"])
        default:
            respondError(id: id, message: "Unsupported request \(method)")
        }
    }

    private func askApproval(title: String, body: String, _ done: @escaping (Decision) -> Void) {
        onEvent?(.waiting(true))
        onEvent?(.activity("Waiting for permission"))
        Task { @MainActor [weak self] in
            guard let self else { return }
            let a = await AgentRuntime.shared.ask(icon: CodingTools.codexIcon, title: title, body: body, options: ["Allow", "Always allow", "Deny"], freeText: false)
            let l = a.lowercased()
            let d: Decision = l.hasPrefix("always") ? .allowSession
                : (l.hasPrefix("allow") || l == "yes" || l == "ok" || l == "okay" || l == "sure" || l == "go ahead") ? .allow : .deny
            self.q.async { self.onEvent?(.waiting(false)); done(d) }
        }
    }

    // MARK: exec fallback

    private func fallbackToExec(_ message: String) {
        guard transport == .appServer else { return }
        transport = .exec
        initialized = false
        pending.removeAll()
        runner?.kill()
        runner = nil
        onEvent?(.activity("Using codex exec"))
        runExec(message)
    }

    private func runExec(_ message: String) {
        guard let bin = Self.binary else { return }
        turnActive = true
        agentText = ""; lastAgentMessage = ""
        var args = ["exec"]
        if let t = threadId { args += ["resume", t] }
        args += ["--json", "--skip-git-repo-check", "--sandbox", sandbox, "-c", "approval_policy=never"]
        if let m = model, !m.isEmpty { args += ["--model", m] }
        if let e = effort, !e.isEmpty { args += ["-c", "model_reasoning_effort=\"\(Self.normalizeEffort(e))\""] }
        args.append(message)
        let r = ProcessRunner(executable: bin, arguments: args, cwd: project)
        r.onLine = { [weak self] line in self?.q.async { self?.handleExec(line: line) } }
        r.onStderr = { s in
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !t.contains("failed to load skill") { Log.warn("codex exec stderr: \(t.prefix(300))") }
        }
        r.onExit = { [weak self] code in
            guard let self else { return }
            self.q.async {
                if self.turnActive {
                    self.turnActive = false
                    let text = self.lastAgentMessage.isEmpty ? self.agentText : self.lastAgentMessage
                    if self.stopping { self.onEvent?(.turnDone(text: text.isEmpty ? "Stopped." : text, ok: false)) }
                    else { self.onEvent?(.turnDone(text: text.isEmpty ? "Codex exited (code \(code))." : text, ok: code == 0)) }
                }
                self.onEvent?(.exited(code: code))
                if !self.queued.isEmpty { self.runExec(self.queued.removeFirst()) }
            }
        }
        do { try r.start(); runner = r; stopping = false }
        catch { turnActive = false; onEvent?(.turnDone(text: "Could not launch codex exec: \(error.localizedDescription)", ok: false)) }
    }

    private func handleExec(line: String) {
        guard line.hasPrefix("{"), let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
        let type = obj["type"] as? String ?? ""
        switch type {
        case "thread.started":
            if let t = obj["thread_id"] as? String { threadId = t; onEvent?(.sessionId(t)) }
        case "item.started", "item.completed":
            guard let item = obj["item"] as? [String: Any] else { return }
            switch item["type"] as? String {
            case "agent_message":
                if type == "item.completed", let t = item["text"] as? String, !t.isEmpty { lastAgentMessage = t; onEvent?(.activity(ClaudeCodeSession.firstLine(t))) }
            case "command_execution":
                if type == "item.started", let c = item["command"] as? String { onEvent?(.activity("Running: \(c.prefix(100))")) }
            case "file_change":
                let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { ($0["path"] as? String).map { ($0 as NSString).lastPathComponent } }
                if type == "item.completed", !paths.isEmpty { onEvent?(.activity("Edited \(paths.prefix(3).joined(separator: ", "))")) }
            default: break
            }
        case "turn.completed":
            turnActive = false
            let text = lastAgentMessage.isEmpty ? "Done." : lastAgentMessage
            onEvent?(.turnDone(text: text, ok: true))
        case "turn.failed", "error":
            turnActive = false
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? obj["message"] as? String ?? "Codex failed."
            onEvent?(.turnDone(text: lastAgentMessage.isEmpty ? msg : "\(lastAgentMessage)\n\(msg)", ok: false))
        default: break
        }
    }

    static func normalizeEffort(_ e: String) -> String {
        switch e.lowercased() {
        case "maximum", "max": return "xhigh"
        case "minimal": return "low"
        default: return e.lowercased()
        }
    }
}

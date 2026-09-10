import Foundation

/// Coding-agent tools: dispatch Claude Code / Codex into a project folder, monitor, reply, stop, and read external sessions.
enum CodingTools {
    static func all() -> [Tool] {
        [DispatchClaudeCode(), DispatchCodex(), ListCodingTasks(), GetCodingTask(), ReplyToCodingTask(), StopCodingTask(), ListExternalCodingSessions()]
    }

    static let claudeIcon = "asset:ClaudeCodeIcon"
    static let codexIcon = "asset:CodexIcon"

    // MARK: default agent

    /// Settings → Coding → Default agent. Read straight from UserDefaults so a tool description can
    /// consult it from any context; `Settings.codingDefaultAgent` writes the same key.
    static var defaultAgent: String {
        UserDefaults.standard.string(forKey: "codingDefaultAgent") == "codex" ? "codex" : "claude"
    }

    /// The half of a dispatch tool's description that says who takes an unnamed request. Descriptions
    /// are rebuilt for every turn, so changing the picker changes where the next "have someone look at
    /// this" lands without a restart.
    static func routingRule(for agent: String) -> String {
        let other = agent == "codex" ? "dispatch_claude_code" : "dispatch_codex"
        let otherName = agent == "codex" ? "Claude Code" : "Codex"
        return defaultAgent == agent
            ? "It is also the user's default coding agent, so take any coding request that names no agent at all — 'get someone to look at the build script in my blog'."
            : "When the user names no agent at all, use \(other) instead: \(otherName) is their default coding agent."
    }

    // MARK: shared dispatch

    static let dispatchParams: [ToolParam] = [
        ToolParam("instruction", "string", "Everything the coding agent needs, self-contained, since none of this conversation reaches it. Spell out the work, name any files or features the user brought up, and say how the result should be checked — running the test suite, for instance.", required: true),
        ToolParam("project", "string", "Which folder to work in. Either give a full path, with ~/… accepted, or simply repeat the folder name the way the user said it ('my blog', 'avo'); Avo searches under their home directory for the closest match and reports back which one it chose. Where the user plainly means a project they were just in, use that path. Asking them is a last resort, for when no name was given at all.", required: true),
        ToolParam("title", "string", "An optional label for the task's row, three to six words long — something along the lines of 'Fix flaky auth tests'."),
        ToolParam("mode", "string", "With 'code', which applies by default, the agent may modify files and execute commands inside the folder. Choose 'read_only' when the job is to examine, review or explain something, since nothing on disk is then touched.", enumValues: ["code", "read_only"]),
        ToolParam("model", "string", "Which model handles the work. Unless the user names one, scale it to how big the job is. On Claude Code that means sonnet for the smallest jobs, opus in the middle and by default, fable for the largest. On Codex it means gpt-5.6-luna for the smallest and as the default, gpt-5.16-soul for the largest, and gpt-6-astra strictly where the user has asked for it by name. Either way the card lets them change it afterwards."),
        ToolParam("effort", "string", "Optional. How hard the user wants the model to think, from low through medium, high and xhigh up to max. Where Codex speaks of maximum, translate that to xhigh; where Claude Code speaks of minimal, translate that to low."),
    ]

    static func dispatch(agent: String, args: [String: Any], ctx: ToolContext) async -> ToolResult {
        guard let instructionRaw = JSON.string(args["instruction"])?.trimmingCharacters(in: .whitespacesAndNewlines), !instructionRaw.isEmpty else {
            return .fail("instruction is required", guidance: "Write a standalone instruction for the agent.")
        }
        guard let projectQuery = JSON.string(args["project"])?.trimmingCharacters(in: .whitespacesAndNewlines), !projectQuery.isEmpty else {
            return .fail("project is required", guidance: "Pass the folder name the user said, or a path. Recent projects: \(ProjectResolver.recent.map(ProjectResolver.abbreviated).joined(separator: ", "))")
        }
        let binary = agent == "codex" ? CodexSession.binary : ClaudeCodeSession.binary
        guard binary != nil else {
            return .fail("\(agent == "codex" ? "codex" : "claude") CLI not found", guidance: "Tell the user the \(agent == "codex" ? "Codex" : "Claude Code") CLI is not installed or not on their login-shell PATH.")
        }
        let matches = await Task.detached(priority: .userInitiated) { ProjectResolver.candidates(projectQuery, limit: 4) }.value
        guard let best = matches.first else {
            return .fail("No folder matching '\(projectQuery)' under the home directory.",
                         guidance: "Ask the user which folder they mean, or try a different name. Recent projects: \(ProjectResolver.recent.map(ProjectResolver.abbreviated).joined(separator: ", "))")
        }
        let mode = (JSON.string(args["mode"]) ?? "code") == "read_only" ? "read_only" : "code"
        let model = JSON.string(args["model"]).flatMap { $0.isEmpty ? nil : $0 } ?? ModelCatalog.defaultModel(for: agent).id
        let effort = JSON.string(args["effort"]).flatMap { $0.isEmpty ? nil : $0 }
        let title = JSON.string(args["title"]).flatMap { $0.isEmpty ? nil : $0 } ?? Self.autoTitle(instructionRaw)
        let instruction = Self.augment(instructionRaw, ctx: ctx)

        let task = await MainActor.run {
            CodingTaskStore.shared.dispatch(agent: agent, title: title, project: best.path, instruction: instruction, mode: mode, model: model, effort: effort)
        }
        var json: [String: Any] = [
            "ok": task.status != "failed",
            "task_id": task.id,
            "agent": task.agentLabel,
            "title": task.title,
            "project": ProjectResolver.abbreviated(best.path),
            "mode": mode,
            "status": task.status,
            "note": "Task started in the background. Its result will pop up on the notch when the agent finishes; the user does not need to wait. Tell the user which folder was picked in a few words.",
        ]
        if task.status == "failed" { json["error"] = task.result ?? "failed to start" }
        if matches.count > 1 { json["other_candidates"] = matches.dropFirst().map { ProjectResolver.abbreviated($0.path) } }
        return .ok(json)
    }

    /// Fold this turn's screen context into the instruction when the user is pointing at something on screen.
    static func augment(_ instruction: String, ctx: ToolContext) -> String {
        var extra: [String] = []
        let t = ctx.transcript.lowercased()
        let refersToScreen = ["screen", "screenshot", "this", "that", "here", "looking at", "see", "selected", "highlighted", "circled", "error", "what's on"].contains { t.contains($0) }
        if !ctx.attachments.isEmpty {
            extra.append("The user marked things on screen while asking; screenshots with their marks: " + ctx.attachments.joined(separator: ", "))
        } else if refersToScreen, let s = ctx.screenshotPath {
            extra.append("Screenshot of the user's screen at the time of the request: \(s)")
        }
        if refersToScreen, let sel = ctx.selectedText, !sel.trimmingCharacters(in: .whitespaces).isEmpty {
            extra.append("Text the user had selected in \(ctx.frontmostApp ?? "the front app"):\n\"\"\"\n\(sel.prefix(3000))\n\"\"\"")
        }
        guard !extra.isEmpty else { return instruction }
        return instruction + "\n\nContext from Avo (the user's voice assistant):\n" + extra.joined(separator: "\n")
    }

    static func autoTitle(_ instruction: String) -> String {
        let first = instruction.split(separator: "\n").first.map(String.init) ?? instruction
        let words = first.split(separator: " ").prefix(6).joined(separator: " ")
        let t = words.trimmingCharacters(in: .punctuationCharacters)
        return t.count > 48 ? String(t.prefix(48)) + "…" : t
    }

    static func summary(_ t: CodingTask, full: Bool) -> [String: Any] {
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"
        var j: [String: Any] = [
            "task_id": t.id, "agent": t.agentLabel, "title": t.title, "project": ProjectResolver.abbreviated(t.project),
            "mode": t.mode, "status": t.status, "started": f.string(from: t.createdAt),
        ]
        if let d = t.finishedAt { j["finished"] = f.string(from: d) }
        if let l = t.activity.last { j["last_activity"] = l }
        if full {
            j["instruction"] = String(t.instruction.prefix(1200))
            j["recent_activity"] = Array(t.activity.suffix(8))
            if let r = t.result { j["result"] = r }
            if let s = t.sessionId { j["session_id"] = s }
        } else if let r = t.result, !t.isActive { j["result"] = String(r.prefix(300)) }
        return j
    }

    // MARK: - Tools

    struct DispatchClaudeCode: Tool {
        let name = "dispatch_claude_code"
        var description: String {
            "Start a Claude Code coding task in a project folder on this Mac and return immediately; the agent works in the background and its result pops up on the notch when it finishes (the user answers its questions and permission prompts by voice or click). Use it whenever the user names Claude for code written, fixed, refactored, explained, reviewed, tested, or a repo investigated — 'have Claude fix the login bug in avo', 'ask Claude Code to add tests'. "
            + CodingTools.routingRule(for: "claude")
            + " Give a standalone instruction: the agent cannot see this conversation. Current-turn screen context is attached automatically when the user refers to it. No confirmation is needed — dispatching is safe; the agent asks before anything destructive."
        }
        let params = CodingTools.dispatchParams
        let statusLabel = "Starting Claude Code"
        let statusIcon = CodingTools.claudeIcon
        let group = "Coding"
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult { await CodingTools.dispatch(agent: "claude", args: args, ctx: ctx) }
    }

    struct DispatchCodex: Tool {
        let name = "dispatch_codex"
        var description: String {
            "Start an OpenAI Codex coding task in a project folder on this Mac and return immediately; Codex works in the background and its result pops up on the notch when it finishes (the user answers its questions and approval prompts by voice or click). Use it when the user names Codex — 'have Codex refactor the parser in avo', 'ask Codex to review this'. "
            + CodingTools.routingRule(for: "codex")
            + " Give a standalone instruction: Codex cannot see this conversation. Current-turn screen context is attached automatically when the user refers to it. No confirmation is needed — dispatching is safe; Codex runs in a workspace sandbox and asks before leaving it."
        }
        let params = CodingTools.dispatchParams
        let statusLabel = "Starting Codex"
        let statusIcon = CodingTools.codexIcon
        let group = "Coding"
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult { await CodingTools.dispatch(agent: "codex", args: args, ctx: ctx) }
    }

    struct ListCodingTasks: Tool {
        let name = "list_coding_tasks"
        let description = "Shows the coding tasks running in the background under Claude Code or Codex, latest first. It ONLY reports state; to START work, the dispatch tools are what you want. Questions like 'what are my agents doing', 'is the avo task done' and 'any coding tasks running' land here."
        let params = [ToolParam("status", "string", "Pick 'active' to cover anything queued, in progress, or waiting, and 'done' for tasks that finished, failed, or were stopped. Leaving it out gives 'all', meaning recent tasks whatever their state.", enumValues: ["all", "active", "done"])]
        let statusLabel = "Checking tasks"
        let statusIcon = CodingTools.claudeIcon
        let group = "Coding"
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let filter = JSON.string(args["status"]) ?? "all"
            let tasks = await MainActor.run { CodingTaskStore.shared.tasks }
            let sel = tasks.filter { t in
                switch filter {
                case "active": return t.isActive
                case "done": return !t.isActive
                default: return true
                }
            }.prefix(12)
            let rows = sel.map { t -> GlanceCard.Row in
                let tone: GlanceCard.Tone = t.status == "done" ? .good : (t.status == "failed" || t.status == "stopped") ? .bad : t.status == "waiting" ? .accent : .neutral
                return GlanceCard.Row(title: t.title, subtitle: "\(t.agentLabel) · \(t.projectName)" + (t.activity.last.map { " · \($0)" } ?? ""),
                                      icon: t.agent == "codex" ? CodingTools.codexIcon : CodingTools.claudeIcon, trailing: t.status.capitalized, tone: tone, path: t.project)
            }
            var cards: [CardKind] = []
            if !rows.isEmpty {
                cards = [.glance(GlanceCard(id: UUID(), blocks: [.header(title: "Coding tasks", subtitle: "\(sel.count) shown", icon: CodingTools.claudeIcon), .list(rows: Array(rows.prefix(6)))], source: "Coding agents", sourceIcon: CodingTools.claudeIcon))]
            }
            return .ok(["ok": true, "count": sel.count, "tasks": sel.map { CodingTools.summary($0, full: false) }], cards: cards)
        }
    }

    struct GetCodingTask: Tool {
        let name = "get_coding_task"
        let description = "Reports where a single coding task stands, and hands back the whole result once it has completed. It answers questions about a task's progress and about what the agent discovered or changed. Identify the task by its id, the first characters of that id, or words drawn from its title or project."
        let params = [ToolParam("task", "string", "The task id, an id prefix, or the title / project name the user used (e.g. 'avo', 'auth tests').", required: true)]
        let statusLabel = "Checking task"
        let statusIcon = CodingTools.claudeIcon
        let group = "Coding"
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let ref = JSON.string(args["task"]) ?? ctx.openCardTaskId ?? ""
            guard let t = await MainActor.run(body: { CodingTaskStore.shared.find(ref) }) else {
                return .fail("No coding task matching '\(ref)'", guidance: "Call list_coding_tasks to see ids.")
            }
            let card = await MainActor.run { () -> CardKind in
                var c = TaskCard(id: UUID(), taskId: t.id, agent: t.agentLabel, title: t.title, status: t.status == "stopped" ? "failed" : (t.status == "queued" ? "running" : t.status),
                                 lines: Array(t.activity.suffix(30)), result: t.result.map(CodingTaskStore.trimResult),
                                 project: (t.project as NSString).abbreviatingWithTildeInPath, startedAt: t.createdAt, finishedAt: t.finishedAt,
                                 agentKey: t.agent, model: t.model, effort: t.effort)
                c.onAction = { a in
                    Task { @MainActor in
                        if a == "stop" { _ = CodingTaskStore.shared.stop(t.id) } else if a == "open" { CodingTaskStore.shared.openInFinder(t.id) }
                    }
                }
                return .task(c)
            }
            var j = CodingTools.summary(t, full: true); j["ok"] = true
            return .ok(j, cards: [card])
        }
    }

    struct ReplyToCodingTask: Tool {
        let name = "reply_to_coding_task"
        let description = "Carries a further instruction, an answer, or a correction into the ONE coding session currently shown on the notch card, whose id appears in the OPEN CODING TASK CARD context; because it re-enters the same Claude Code or Codex session, everything that session already knows stays intact. ONLY requests about that visible session belong here — anything unrelated needs a dispatch tool and a session of its own, and no other id is accepted. A session still mid-work queues the message and picks it up when the present work concludes, so it NEVER cuts into or redirects the run under way; one that has already ended is resumed. Screen context from this turn attaches by itself whenever the user points at it."
        let params = [
            ToolParam("task_id", "string", "Whatever task id the OPEN CODING TASK CARD context spells out, copied exactly.", required: true),
            ToolParam("message", "string", "The follow-up instruction or answer, written to stand alone.", required: true),
        ]
        let statusLabel = "Replying to agent"
        let statusIcon = CodingTools.claudeIcon
        let group = "Coding"
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let msg = JSON.string(args["message"])?.trimmingCharacters(in: .whitespacesAndNewlines), !msg.isEmpty else { return .fail("message is required") }
            let ref = JSON.string(args["task_id"]) ?? ctx.openCardTaskId ?? ""
            let text = CodingTools.augment(msg, ctx: ctx)
            let (task, err): (CodingTask?, String?) = await MainActor.run {
                guard let t = CodingTaskStore.shared.find(ref) else { return (nil, "No coding task matching '\(ref)'") }
                return (t, CodingTaskStore.shared.reply(t.id, text: text))
            }
            guard let t = task else { return .fail(err ?? "not found", guidance: "Only the task on the open card can be replied to; otherwise dispatch a new task.") }
            if let e = err { return .fail(e) }
            return .ok(["ok": true, "task_id": t.id, "agent": t.agentLabel, "status": "running",
                        "note": "Follow-up sent to the same session. Its reply will pop up on the notch when ready."])
        }
    }

    struct StopCodingTask: Tool {
        let name = "stop_coding_task"
        let description = "Stop a running Claude Code / Codex task (sends an interrupt, then terminates). Use for 'stop the agent', 'cancel the coding task'. Accepts the task id, an id prefix, or words from its title; with no argument stops the task on the open card, or the only active one."
        let params = [ToolParam("task", "string", "Task id, id prefix, or title words. Omit to stop the task whose card is open (or the single active task).")]
        let statusLabel = "Stopping task"
        let statusIcon = CodingTools.claudeIcon
        let group = "Coding"
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let ref = JSON.string(args["task"]) ?? ctx.openCardTaskId ?? ""
            let result: (String?, String?) = await MainActor.run {
                let store = CodingTaskStore.shared
                var t = store.find(ref)
                if t == nil, ref.isEmpty { let active = store.tasks.filter { $0.isActive }; if active.count == 1 { t = active.first } }
                guard let t else { return (nil, "No task matching '\(ref)'") }
                _ = store.stop(t.id)
                return (t.id, nil)
            }
            if let e = result.1 { return .fail(e, guidance: "Call list_coding_tasks status=active to see ids.") }
            return .ok(["ok": true, "task_id": result.0 ?? "", "status": "stopped"])
        }
    }

    struct ListExternalCodingSessions: Tool {
        let name = "list_external_coding_sessions"
        let description = "Reads the local session stores kept by the Claude Code and Codex CLIs to show sessions the user started somewhere other than Avo — a terminal, an IDE, or the Claude and Codex desktop apps. STRICTLY READ-ONLY: Avo has no way to answer, redirect, or halt these sessions, so never suggest otherwise. It belongs on questions about what a terminal or desktop coding agent is doing or has done. Tasks Avo itself dispatched are NOT listed here; those are list_coding_tasks. Treat approx_state as a guess drawn from file activity, where 'active' means something was written in roughly the last two minutes."
        let params = [ToolParam("project", "string", "Optional. Narrows the list to sessions whose working directory includes this substring — typically a project folder's name.")]
        let statusLabel = "Reading sessions"
        let statusIcon = CodingTools.claudeIcon
        let group = "Coding"
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let filter = JSON.string(args["project"])?.lowercased()
            let sessions = await Task.detached(priority: .utility) { ExternalSessions.recent(limit: 10) }.value
            let sel = sessions.filter { s in filter.map { s.cwd.lowercased().contains($0) } ?? true }
            let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"
            let rows = sel.prefix(6).map { s in
                GlanceCard.Row(title: s.prompt.isEmpty ? "(no prompt)" : String(s.prompt.prefix(70)),
                               subtitle: "\(s.agent) · \(ProjectResolver.abbreviated(s.cwd))",
                               icon: s.agent == "Codex" ? CodingTools.codexIcon : CodingTools.claudeIcon,
                               trailing: s.state == "active" ? "Active" : f.string(from: s.modified),
                               tone: s.state == "active" ? .good : .neutral, path: s.cwd)
            }
            let cards: [CardKind] = rows.isEmpty ? [] : [.glance(GlanceCard(id: UUID(), blocks: [.header(title: "External sessions", subtitle: "Terminal / IDE / desktop apps", icon: CodingTools.claudeIcon), .list(rows: Array(rows))], source: "Local session stores", sourceIcon: CodingTools.claudeIcon))]
            let json = sel.map { s -> [String: Any] in
                ["session_id": s.id, "agent": s.agent, "cwd": ProjectResolver.abbreviated(s.cwd), "first_prompt": String(s.prompt.prefix(240)),
                 "last_assistant_text": String(s.lastAssistant.prefix(400)), "modified": f.string(from: s.modified), "approx_state": s.state]
            }
            return .ok(["ok": true, "count": sel.count, "sessions": json, "note": "Read-only; these sessions cannot be controlled from Avo."], cards: cards)
        }
    }
}

// MARK: - External session stores (read-only)

enum ExternalSessions {
    struct Session {
        var id: String
        var agent: String        // "Claude Code" | "Codex"
        var cwd: String
        var prompt: String
        var lastAssistant: String
        var modified: Date
        var state: String        // active | idle
    }

    static func recent(limit: Int) -> [Session] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var files: [(URL, Date, String)] = []
        let claudeRoot = home.appendingPathComponent(".claude/projects")
        if let projects = try? FileManager.default.contentsOfDirectory(at: claudeRoot, includingPropertiesForKeys: nil) {
            for p in projects {
                guard let fs = try? FileManager.default.contentsOfDirectory(at: p, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                for f in fs where f.pathExtension == "jsonl" {
                    let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    files.append((f, m, "claude"))
                }
            }
        }
        let codexRoot = home.appendingPathComponent(".codex/sessions")
        if let e = FileManager.default.enumerator(at: codexRoot, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let f as URL in e where f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                files.append((f, m, "codex"))
            }
        }
        files.sort { $0.1 > $1.1 }
        var out: [Session] = []
        for (url, mtime, kind) in files.prefix(limit * 2) {
            if let s = kind == "claude" ? parseClaude(url, mtime: mtime) : parseCodex(url, mtime: mtime) { out.append(s) }
            if out.count >= limit { break }
        }
        return out
    }

    /// Read at most the first `head` bytes and last `tail` bytes of a possibly huge JSONL file.
    private static func headTail(_ url: URL, head: Int = 400_000, tail: Int = 300_000) -> (String, String) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return ("", "") }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: 0)
        let headData = (try? h.read(upToCount: min(head, Int(size)))) ?? Data()
        var tailData = Data()
        if size > UInt64(head) {
            try? h.seek(toOffset: size - UInt64(min(tail, Int(size))))
            tailData = (try? h.readToEnd()) ?? Data()
        } else { tailData = headData }
        return (String(decoding: headData, as: UTF8.self), String(decoding: tailData, as: UTF8.self))
    }

    private static func obj(_ line: Substring) -> [String: Any]? {
        guard line.hasPrefix("{") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    private static func textOf(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { b -> String? in
                switch b["type"] as? String {
                case "text", "input_text", "output_text": return b["text"] as? String
                default: return nil
                }
            }.joined(separator: "\n")
        }
        return ""
    }

    private static func isSystemish(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty || s.hasPrefix("<") || s.hasPrefix("#") || s.hasPrefix("Caveat:") || s.contains("hookSpecificOutput")
    }

    private static func parseClaude(_ url: URL, mtime: Date) -> Session? {
        let (head, tail) = headTail(url)
        var cwd = ""; var prompt = ""; var last = ""
        for line in head.split(separator: "\n") {
            guard let o = obj(line) else { continue }
            if cwd.isEmpty, let c = o["cwd"] as? String { cwd = c }
            if prompt.isEmpty, o["type"] as? String == "user", o["isSidechain"] as? Bool != true, let m = o["message"] as? [String: Any] {
                let t = textOf(m["content"])
                if !isSystemish(t) { prompt = ClaudeCodeSession.firstLine(t) }
            }
            if !cwd.isEmpty && !prompt.isEmpty { break }
        }
        for line in tail.split(separator: "\n").reversed() {
            guard let o = obj(line), o["type"] as? String == "assistant", let m = o["message"] as? [String: Any] else { continue }
            let t = textOf(m["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { last = t; break }
        }
        guard !cwd.isEmpty || !prompt.isEmpty else { return nil }
        return Session(id: url.deletingPathExtension().lastPathComponent, agent: "Claude Code", cwd: cwd, prompt: prompt, lastAssistant: last,
                       modified: mtime, state: Date().timeIntervalSince(mtime) < 120 ? "active" : "idle")
    }

    private static func parseCodex(_ url: URL, mtime: Date) -> Session? {
        let (head, tail) = headTail(url)
        var cwd = ""; var id = url.deletingPathExtension().lastPathComponent; var prompt = ""; var last = ""
        for line in head.split(separator: "\n") {
            guard let o = obj(line), let p = o["payload"] as? [String: Any] else { continue }
            if o["type"] as? String == "session_meta" {
                cwd = p["cwd"] as? String ?? cwd
                id = p["id"] as? String ?? id
            } else if prompt.isEmpty, o["type"] as? String == "response_item", p["type"] as? String == "message", p["role"] as? String == "user" {
                let t = textOf(p["content"])
                if !isSystemish(t) { prompt = ClaudeCodeSession.firstLine(t) }
            }
            if !cwd.isEmpty && !prompt.isEmpty { break }
        }
        for line in tail.split(separator: "\n").reversed() {
            guard let o = obj(line), let p = o["payload"] as? [String: Any] else { continue }
            if o["type"] as? String == "event_msg", p["type"] as? String == "task_complete", let m = p["last_agent_message"] as? String, !m.isEmpty { last = m; break }
            if o["type"] as? String == "response_item", p["type"] as? String == "message", p["role"] as? String == "assistant" {
                let t = textOf(p["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { last = t; break }
            }
        }
        guard !cwd.isEmpty else { return nil }
        return Session(id: id, agent: "Codex", cwd: cwd, prompt: prompt, lastAssistant: last, modified: mtime,
                       state: Date().timeIntervalSince(mtime) < 120 ? "active" : "idle")
    }
}

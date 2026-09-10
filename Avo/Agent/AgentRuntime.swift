import Foundation
import AppKit

/// One turn = transcript + context → model → tools (with confirmation gating) → narration.
@MainActor
final class AgentRuntime {
    static let shared = AgentRuntime()
    private let notch = NotchController.shared
    private var running = false
    private var currentTask: Task<Void, Never>?
    private var currentTurnID: UUID?
    private var conversation: [[String: Any]] = []     // Responses API input items for this session
    private var lastActivity = Date()
    /// Confirmation card waiting for a yes/no; a new voice turn can resolve it.
    private var pendingConfirmation: (id: UUID, resolve: (ConfirmationCard.Decision) -> Void)?
    private var pendingQuestion: (id: UUID, resolve: (String) -> Void)?

    var isRunning: Bool { running }

    // MARK: session policy
    private var lastTurnEnded = Date.distantPast
    /// Set by the notch when a request begins while the previous reply is still on screen, or when
    /// the user reopens an exchange from the side notch. Either means "continue this chat".
    var requestBeganWhileOpen = false
    /// The user reopened a past exchange from the side notch: make it the current chat so the next
    /// request continues it (text only; the original screenshot is not resent).
    /// Groups History entries; a fresh id whenever a request starts a new chat.
    private var chatId = UUID()

    /// Continue a past chat: its turns become the model context again (text only; screenshots and
    /// tool results are not kept in History).
    func resume(chat: History.Chat) {
        chatId = chat.id
        conversation = chat.entries.map { e in
            e.role == "user"
                ? ["role": "user", "content": [["type": "input_text", "text": "User said: \(e.text)"]]]
                : ["role": "assistant", "content": [["type": "output_text", "text": e.text]]]
        }
        requestBeganWhileOpen = true
        lastActivity = Date()
    }
    /// A request is a follow-up only when a card is waiting, the last reply was still open, or the
    /// last turn ended under 90 s ago. Everything else starts a fresh chat.
    private var isFollowUp: Bool {
        pendingConfirmation != nil || pendingQuestion != nil || requestBeganWhileOpen
            || Date().timeIntervalSince(lastTurnEnded) < 90
    }
    /// The current turn is parked on a confirmation or question card. The next spoken phrase is
    /// most likely its answer, so callers must not cancel the turn just because it is "running".
    var isAwaitingUser: Bool { pendingConfirmation != nil || pendingQuestion != nil }

    // MARK: entry points

    func run(text rawText: String, forcedDeep: Bool = false) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { notch.collapse(); return }
        // A voice reply while a card is open resolves the card without a model call when it's a plain answer.
        if let pending = pendingConfirmation, let decision = QuickIntent.confirmDecision(text) {
            pendingConfirmation = nil
            ContextBuilder.shared.discardDraft()
            notch.model.transcript = text
            pending.resolve(decision)
            return
        }
        if let q = pendingQuestion {
            pendingQuestion = nil
            ContextBuilder.shared.discardDraft()
            q.resolve(text)
            return
        }
        // A non-answer is a fresh request. Resolve any suspended UI continuation before replacing
        // the turn, otherwise the old tool/coding session remains hung forever behind its card.
        resolvePendingInteractions()
        if running { currentTask?.cancel() }
        let turnID = UUID()
        currentTurnID = turnID
        running = true
        let task = Task { await turn(text: text, forcedDeep: forcedDeep) }
        currentTask = task
        await task.value
        if currentTurnID == turnID {
            currentTurnID = nil
            currentTask = nil
            running = false
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        currentTurnID = nil
        running = false
        resolvePendingInteractions()
    }

    private func resolvePendingInteractions() {
        let confirmation = pendingConfirmation
        pendingConfirmation = nil
        confirmation?.resolve(.cancel)
        let question = pendingQuestion
        pendingQuestion = nil
        question?.resolve("")
    }

    // MARK: turn

    private func turn(text: String, forcedDeep: Bool) async {
        let turnId = UUID()
        let settings = Settings.shared
        Log.info("Turn start: \(text.prefix(120))")
        // Fresh chat per request unless it is plainly a follow-up. Before this, one session grew until
        // 20 minutes of silence and every turn re-sent all of it (screenshots included): ~38K input
        // tokens per turn today, 834K over 22 turns, for 3K tokens of answers.
        let stale = Date().timeIntervalSince(lastActivity) > 20 * 60
        let fresh = stale || conversation.isEmpty || !isFollowUp
        let previous = (user: notch.model.transcript, reply: notch.model.responseText)
        notch.clearResponse()
        notch.model.transcript = text
        notch.model.phase = .thinking
        if fresh {
            chatId = UUID()
            notch.model.priorTurns = []
        } else if !previous.user.isEmpty, !previous.reply.isEmpty {
            // The thread stays on screen above the new turn.
            notch.model.priorTurns.append(.init(id: UUID(), user: previous.user, reply: previous.reply))
        }
        if stale { await rollOverSession() }
        else if !conversation.isEmpty, !isFollowUp { conversation = [] }
        lastActivity = Date()
        requestBeganWhileOpen = false
        // Earlier screenshots never help the next request and cost ~1K tokens each, every turn.
        conversation = conversation.map(Self.strippingImages)

        // Context
        let snap = await ContextBuilder.shared.build(turnId: turnId, transcript: text)
        guard !Task.isCancelled else { return }
        notch.showContextChips(selectionWords: snap.selectedText.map(ContextBuilder.wordCount),
                               screenPath: snap.imagePaths.first { !snap.gestureImagePaths.contains($0) && !snap.attachments.contains($0) },
                               marks: snap.gestureImagePaths.count, markPath: snap.gestureImagePaths.first)
        let ctx = ToolContext(turnId: turnId, screenshotPath: snap.imagePaths.first, selectedText: snap.selectedText,
                              frontmostApp: snap.frontmostApp, frontmostBundleId: snap.frontmostBundleId, clipboard: snap.clipboard,
                              openCardTaskId: nil, attachments: snap.gestureImagePaths + snap.attachments, transcript: text)
        let deep = forcedDeep || settings.deepMode || QuickIntent.wantsDeep(text)
        notch.model.deepMode = deep

        // Build input: prior conversation + this user message (with screenshot/attachments as images)
        var userContent: [[String: Any]] = [["type": "input_text", "text": ContextBuilder.shared.render(snap)]]
        for path in snap.imagePaths {
            let encoded = await Task.detached(priority: .userInitiated) { ImageInput.encode(path: path) }.value
            guard !Task.isCancelled else { return }
            guard let encoded else {
                notch.fail("Couldn't read an attached image. Reattach it and try again.")
                return
            }
            userContent.append(["type": "input_image", "image_url": encoded.url, "detail": "auto"])
            Log.info("Image input: \(encoded.bytes) bytes")
        }
        conversation.append(["role": "user", "content": userContent])
        History.shared.record(role: "user", text: text, chat: chatId)

        let tools = ToolRegistry.shared.enabled()
        let toolDefs = tools.map { $0.openAIDefinition }
        let instructions = SystemPrompt.build(includeVoice: QuickIntent.wantsWriting(text))
        var narration = ""
        let requestStarted = Date()
        var receivedFirstOutput = false

        let llm = Brain.client()

        loop: for hop in 0..<8 {
            if Task.isCancelled { return }
            let effort = deep ? settings.deepEffort : settings.brainEffort
            var pendingCalls: [(callId: String, name: String, args: String)] = []
            var text = ""
            var failed: String?
            var searchChip: UUID?
            var citations: [(String, String)] = []
            let stream = llm.stream(model: settings.brainModel, effort: effort, instructions: instructions,
                                    input: conversation, tools: toolDefs)
            for await ev in stream {
                if Task.isCancelled { return }
                switch ev {
                case .textDelta(let d):
                    if !receivedFirstOutput {
                        receivedFirstOutput = true
                        Log.info("Voice timing: request-to-first-text=\(Int(Date().timeIntervalSince(requestStarted) * 1000))ms")
                    }
                    text += d
                    notch.appendResponse(d)
                    Speech.shared.feed(d)
                case .toolCall(_, let callId, let name, let args):
                    Log.info("Tool call: \(name) \(args.prefix(200))")
                    pendingCalls.append((callId, name, args))
                case .reasoningSummary: break
                case .webSearchStarted:
                    if searchChip == nil { searchChip = notch.status("Searching the web", icon: "globe") }
                case .citation(let title, let url):
                    if !citations.contains(where: { $0.1 == url }) { citations.append((title, url)) }
                case .completed(_, let usage): logUsage(usage, model: settings.brainModel)
                case .error(let e): failed = e; Log.error("LLM error: \(e)")
                }
            }
            // Cancelling the task ends the stream with nil rather than throwing, so the loop above
            // exits normally. Without this check a superseded turn fell through to `notch.done()`:
            // it flipped the *new* listen to the done state, chimed, and armed a collapse timer.
            if Task.isCancelled { Log.info("Turn cancelled"); return }
            if let c = searchChip { notch.finishStatus(c, ok: failed == nil) }
            presentSources(citations)
            if let f = failed { lastTurnEnded = Date(); notch.fail(friendly(f)); History.shared.record(role: "assistant", text: "Error: \(f)", chat: chatId); return }
            if !text.isEmpty {
                conversation.append(["role": "assistant", "content": [["type": "output_text", "text": text]]])
                narration = text
            }
            if pendingCalls.isEmpty { break loop }

            // Run tool calls sequentially (confirmations need order); parallel-safe reads could be concurrent later.
            var quickNarrations: [String] = []
            var allQuick = true
            for call in pendingCalls {
                if Task.isCancelled { return }
                let result = await execute(call.name, argsJSON: call.args, ctx: ctx)
                if Task.isCancelled { return }
                conversation.append(["type": "function_call", "call_id": call.callId, "name": call.name, "arguments": call.args])
                conversation.append(["type": "function_call_output", "call_id": call.callId, "output": JSON.stringify(result.json)])
                if !result.imagePaths.isEmpty {
                    var content: [[String: Any]] = [["type": "input_text", "text": "(Image(s) from \(call.name).)"]]
                    for path in result.imagePaths {
                        if let enc = await Task.detached(priority: .userInitiated, operation: { ImageInput.encode(path: path) }).value {
                            content.append(["type": "input_image", "image_url": enc.url, "detail": "auto"])
                        }
                    }
                    if content.count > 1 { conversation.append(["role": "user", "content": content]) }
                    if let p = result.imagePaths.first {
                        notch.showScreenChip(path: p, state: .done, fly: Settings.shared.animateScreenshots, from: NSScreen.main?.frame ?? .zero)
                    }
                }
                for c in result.cards { notch.present(c) }
                // The web_search tool's results are sources behind the answer, exactly like the
                // url_citation annotations the hosted search sends, and get the same card.
                if call.name == "web_search" { presentSources(Self.sources(in: result.json)) }
                if case .cancelled = result.outcome { notch.clearResponse(); Speech.shared.stop() }
                if let n = result.narration { quickNarrations.append(n) } else { allQuick = false }
            }
            // Confirmed actions that succeeded: say the outcome now instead of paying for another model hop.
            if allQuick, !quickNarrations.isEmpty {
                let line = quickNarrations.joined(separator: " ")
                notch.setResponse(line); Speech.shared.stop(); Speech.shared.sayNow(line)
                conversation.append(["role": "assistant", "content": [["type": "output_text", "text": line]]])
                narration = line
                break loop
            }
            // After tools, clear the streamed text so the model's follow-up narration replaces the pre-tool line.
            if hop < 7 { notch.clearResponse(); Speech.shared.flushSentence() }
        }
        Speech.shared.finish()
        lastTurnEnded = Date()
        Log.info("Turn done: \(narration.prefix(160))")
        if !narration.isEmpty { History.shared.record(role: "assistant", text: narration, chat: chatId) }
        notch.done(autoCollapseAfter: notch.model.cards.isEmpty ? 7 : 14)
    }

    /// One card listing what an answer was drawn from. Both routes to the web end here — the hosted
    /// search's `url_citation` annotations, and the `web_search` tool's own results — so a provider
    /// with no built-in search shows the user the same thing OpenAI's does.
    private func presentSources(_ sources: [(String, String)]) {
        guard !sources.isEmpty else { return }
        let rows = sources.prefix(5).map {
            GlanceCard.Row(title: $0.0.isEmpty ? $0.1 : $0.0, subtitle: URL(string: $0.1)?.host, icon: "globe", url: $0.1)
        }
        notch.present(.glance(GlanceCard(id: UUID(), blocks: [.list(rows: rows)], source: "Sources", sourceIcon: "globe")))
    }

    /// `web_search` output as (title, url) pairs. A failed search has no results and shows no card.
    private static func sources(in json: [String: Any]) -> [(String, String)] {
        guard json["ok"] as? Bool == true, let rows = json["results"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let url = row["url"] as? String, !url.isEmpty else { return nil }
            return (row["title"] as? String ?? url, url)
        }
    }

    /// Drops `input_image` parts from a stored user message; text and tool traffic stay.
    private static func strippingImages(_ item: [String: Any]) -> [String: Any] {
        guard item["role"] as? String == "user", let content = item["content"] as? [[String: Any]] else { return item }
        let kept = content.filter { $0["type"] as? String != "input_image" }
        guard kept.count != content.count else { return item }
        var copy = item
        copy["content"] = kept
        return copy
    }

    /// Per-hop token accounting so spend is observable: how much input hit the prompt cache,
    /// how much billed full price, and where output (incl. reasoning) tokens go.
    private func logUsage(_ usage: [String: Any]?, model: String) {
        guard let usage else { return }
        let u = RequestPolicy.Usage(usage)
        // Prices are only known for the OpenAI catalogue, so cost is logged for the Responses style only.
        let counts = "model=\(model) input=\(u.input) cached=\(u.cached) (\(u.hitPercent)%) cache_write=\(u.written) uncached=\(u.ordinary) output=\(u.output) reasoning=\(u.reasoning)"
        guard Brain.style == .responses else { Log.info("Usage: \(counts)"); return }
        let cost = u.estimatedUSD(model: model).map { String(format: "%.6f", $0) } ?? "unknown"
        Log.info("Usage: \(counts) estimated_token_usd=\(cost)")
    }

    // MARK: tool execution with confirmation gating

    private struct Exec { var json: [String: Any]; var cards: [CardKind]; var outcome: Outcome; var narration: String? = nil; var imagePaths: [String] = []; enum Outcome { case ran, cancelled } }

    private func execute(_ name: String, argsJSON: String, ctx: ToolContext) async -> Exec {
        guard let tool = ToolRegistry.shared.tool(name) else {
            return Exec(json: ["ok": false, "error": "Unknown tool \(name)"], cards: [], outcome: .ran)
        }
        var args = JSON.parse(argsJSON)
        if let spec = tool.confirmation, Settings.shared.confirmActions {
            let decision = await confirm(spec, args: args)
            switch decision {
            case .cancel:
                return Exec(json: ["ok": false, "cancelled": true, "note": "User cancelled. Acknowledge briefly, do not retry."], cards: [], outcome: .cancelled)
            case .confirm(let edited):
                for (k, v) in edited { args[k] = coerce(v, like: args[k], tool: tool, key: k) }
            }
        }
        let chip = notch.status(tool.statusLabel, icon: tool.statusIcon)
        let t0 = Date()
        let result: ToolResult
        do {
            let a = args, c = ctx
            result = try await withTimeout(seconds: tool.group == "Coding" ? 20 : 45) { await tool.run(a, ctx: c) }
        } catch {
            result = .fail("\(tool.name) timed out after \(Int(Date().timeIntervalSince(t0)))s. A macOS permission dialog may be waiting; tell the user to check System Settings → Privacy & Security.")
        }
        Log.info("Tool \(tool.name) → ok=\(result.ok) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        notch.finishStatus(chip, ok: result.ok)
        // Read tools: glance/file cards show only when the model asked (`show: true`). Interactive cards always show.
        let wantsShow = (args["show"] as? Bool) ?? ((args["show"] as? String).map { ($0 as NSString).boolValue } ?? false)
        let cards: [CardKind] = (tool.confirmation == nil && !wantsShow) ? result.cards.filter { c in
            switch c { case .glance, .files: return !result.ok   // keep error/connect cards
                       default: return true }
        } : result.cards
        return Exec(json: result.json, cards: cards, outcome: .ran, narration: tool.confirmation != nil && result.ok ? result.narration : nil, imagePaths: result.imagePaths)
    }

    /// Arrays show as "a, b" (coerce splits them back on commas); everything else as its plain string.
    private static func fieldText(_ v: Any?) -> String {
        guard let v else { return "" }
        if let s = JSON.string(v) { return s }
        if let a = v as? [Any] { return a.compactMap { JSON.string($0) }.joined(separator: ", ") }
        return JSON.stringify(v)
    }

    private func coerce(_ s: String, like original: Any?, tool: Tool, key: String) -> Any {
        let p = tool.params.first { $0.name == key }
        switch p?.type {
        case "boolean": return (s as NSString).boolValue
        case "number": return Double(s) ?? 0
        case "integer": return Int(s) ?? 0
        case "array": return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        default: return s
        }
    }

    private func confirm(_ spec: ConfirmationSpec, args: [String: Any]) async -> ConfirmationCard.Decision {
        await withCheckedContinuation { cont in
            let id = UUID()
            var card = ConfirmationCard(id: id, icon: spec.icon, title: spec.title, subtitle: spec.subtitle?(args),
                                        fields: spec.fields.map { f in
                                            .init(id: f.key, label: f.label, kind: f.kind, value: Self.fieldText(args[f.key]), required: f.required)
                                        }, confirmLabel: spec.confirmLabel, destructive: spec.destructive, layout: spec.layout)
            var resolved = false
            let finish: (ConfirmationCard.Decision) -> Void = { [weak self] d in
                guard !resolved else { return }; resolved = true
                self?.pendingConfirmation = nil
                self?.notch.dismissCard(id)
                cont.resume(returning: d)
            }
            card.onDecision = finish
            pendingConfirmation = (id, finish)
            notch.present(.confirmation(card), id: id)
            Speech.shared.sayNow(spec.subtitle?(args).map { "\(spec.title) \($0). Confirm?" } ?? "\(spec.title). Confirm?")
        }
    }

    /// Tools (coding agents) call this to ask the user something.
    func ask(icon: String, title: String, body: String, options: [String], freeText: Bool) async -> String {
        await withCheckedContinuation { cont in
            let id = UUID()
            var resolved = false
            let finish: (String) -> Void = { [weak self] a in
                guard !resolved else { return }; resolved = true
                self?.pendingQuestion = nil
                self?.notch.dismissCard(id)
                cont.resume(returning: a)
            }
            var card = QuestionCard(id: id, icon: icon, title: title, body: body, options: options, allowFreeText: freeText)
            card.onAnswer = finish
            // Two agents can ask at once. Dropping the previous entry stranded its continuation —
            // that tool waited forever, and its card could no longer be answered by voice. Close the
            // old question with an empty answer (what a dismissal gives) before taking its place.
            if let previous = pendingQuestion { previous.resolve("") }
            pendingQuestion = (id, finish)
            notch.present(.question(card), id: id)
            notch.reveal()
            Speech.shared.sayNow(title)
        }
    }

    // MARK: session memory

    private func rollOverSession() async {
        guard !conversation.isEmpty else { return }
        let transcript = conversation.compactMap { item -> String? in
            guard let role = item["role"] as? String, let content = item["content"] as? [[String: Any]] else { return nil }
            let text = content.compactMap { $0["text"] as? String }.joined(separator: " ")
            return "\(role): \(text.prefix(600))"
        }.joined(separator: "\n")
        conversation = []
        guard !transcript.isEmpty else { return }
        Task {
            if let summary = await Brain.client().complete(model: Settings.shared.brainModel, instructions: "Summarize this assistant session in 3-6 terse lines: what the user asked, what was done, open loops. No preamble.", prompt: String(transcript.suffix(12000)), maxTokens: 600) {
                History.shared.addSessionSummary(summary)
            }
        }
    }


    private func friendly(_ e: String) -> String {
        if e.contains("401") || e.lowercased().contains("invalid api key") { return "API key rejected by \(URL(string: Settings.shared.apiBaseURL)?.host ?? "the provider")." }
        if e.contains("429") { return "Rate limited. Try again in a moment." }
        if e.localizedCaseInsensitiveContains("offline") || e.contains("-1009") { return "No internet connection." }
        if e.contains("Could not connect") || e.contains("-1004") || e.contains("-1001") { return "Can't reach \(URL(string: Settings.shared.apiBaseURL)?.host ?? "the provider"). Check Settings → General → Model." }
        return e
    }
}


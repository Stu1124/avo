import Foundation
import AppKit

/// Live voice mode: mic ↔ OpenAI Realtime ↔ speaker, with the same tools and confirmation gating as the text brain.
/// Everything is torn down on stop; nothing is retained while inactive.
@MainActor
final class VoiceModeSession {
    static let shared = VoiceModeSession()
    private let notch = NotchController.shared

    private(set) var isActive = false
    private var client: RealtimeClient?
    private var mic: MicCapture?
    private var player: PCMPlayer?
    private var timer: Timer?
    private var chipId = UUID()
    private var startedAt = Date()
    private var lastActivity = Date()

    private var configured = false
    private var responseInFlight = false
    private var userSpeaking = false
    private var currentItemId: String?
    private var responseText = ""
    private var lastUserText = ""
    private var pendingFunctionCalls = 0
    private var responseCreatePending = false
    private var toolQueue: Task<Void, Never>?
    private var instructions = ""
    private var toolDefs: [[String: Any]] = []
    private var voiceUsed = false
    private var triedLegacy = false
    private var failed = false

    /// Confirmation card waiting for a click or a spoken yes/no.
    private var pendingConfirmation: (id: UUID, resolve: (ConfirmationCard.Decision, String?) -> Void)?

    private static let silenceLimit: TimeInterval = 25
    private static let stopPhrases = ["stop voice mode", "end voice mode", "exit voice mode", "leave voice mode", "goodbye", "good bye", "that's all", "that is all", "thats all"]

    func toggle() {
        if isActive { stop(reason: "toggled off") } else { Task { await start() } }
    }

    // MARK: lifecycle

    /// Why voice mode cannot run right now, or nil when it can. Realtime is OpenAI-only.
    static var unavailableReason: String? {
        guard !Brain.voiceModeAvailable else { return nil }
        if (Settings.shared.apiKey ?? "").isEmpty {
            return "Voice mode needs an OpenAI API key in Settings → General → Model."
        }
        return "Voice mode needs OpenAI (Responses style) in Settings → General → Model."
    }

    func start() async {
        guard !isActive else { return }
        // Single gate for every entry point: the Settings pill, the menu item and avo://voice.
        if let reason = Self.unavailableReason {
            Log.warn("Voice mode unavailable: \(reason)")
            // Reveal first: fail() only sets the model, so a collapsed notch would swallow the message.
            notch.presentIdleHint()
            notch.fail(reason)
            return
        }
        isActive = true
        failed = false; configured = false; responseInFlight = false; userSpeaking = false
        currentItemId = nil; responseText = ""; lastUserText = ""; pendingFunctionCalls = 0
        responseCreatePending = false; voiceUsed = false; triedLegacy = false
        startedAt = Date(); lastActivity = Date()

        notch.beginListening(playSound: false)
        notch.model.transcript = ""
        chipId = notch.status("Voice mode", icon: "waveform", id: UUID())

        guard await MicCapture.requestAccess() else {
            fail("Microphone access is off. Enable it in System Settings → Privacy → Microphone."); return
        }

        // Instructions: same system prompt as the text brain, plus the live-mode rider.
        let snap = await ContextBuilder.shared.build(turnId: UUID(), transcript: "")
        instructions = SystemPrompt.build(compact: true)
            + "\nYou are in live voice mode: speak naturally, brief, interruptible. Use tools the same way. Acting tools still show a confirmation card; wait for the user's yes before assuming it ran."
            + "\n\n" + ContextBuilder.shared.render(snap)
        toolDefs = ToolRegistry.shared.enabled().map { $0.openAIDefinition }
        guard isActive else { return }

        let p = PCMPlayer()
        do { try p.start() } catch { fail("Audio output failed: \(error.localizedDescription)"); return }
        p.onDrained = { [weak self] in Task { @MainActor in self?.playbackDrained() } }
        player = p

        let m = MicCapture(microphoneUID: Settings.shared.microphoneUID)
        m.onChunk = { [weak self] data in self?.client?.appendAudio(data) }
        m.onLevel = { [weak self] lvl in Task { @MainActor in self?.notch.model.audioLevel = lvl } }
        do { try m.start() } catch { fail("Microphone failed: \(error.localizedDescription)"); return }
        mic = m
        Sounds.shared.play(.listenStart)

        connect(legacy: false)

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Log.info("Voice mode started (model \(Settings.shared.realtimeModel))")
    }

    func stop(reason: String = "stopped") {
        guard isActive else { return }
        isActive = false
        let seconds = Int(Date().timeIntervalSince(startedAt))
        Log.info("Voice mode ended (\(reason)) after \(seconds / 60):\(String(format: "%02d", seconds % 60)) — session duration; billing is token-based")
        teardown()
        if let pc = pendingConfirmation {
            pendingConfirmation = nil
            pc.resolve(.cancel, nil)
        }
        notch.model.speaking = false
        notch.model.audioLevel = 0
        _ = notch.status("Voice mode · \(clock(seconds))", icon: "waveform", id: chipId, state: .done)
        Sounds.shared.play(.listenEnd)
        if !failed { notch.done(autoCollapseAfter: notch.model.cards.isEmpty ? 5 : 12) }
    }

    private func fail(_ message: String) {
        failed = true
        Log.error("Voice mode: \(message)")
        notch.fail(message)
        if isActive { stop(reason: "error") } else { teardown() }
    }

    private func teardown() {
        timer?.invalidate(); timer = nil
        toolQueue?.cancel(); toolQueue = nil
        if let c = client {
            if responseInFlight { c.send(["type": "response.cancel"]) }
            c.close()
        }
        client = nil
        mic?.stop(); mic = nil
        player?.shutdown(); player = nil
        instructions = ""; toolDefs = []
        responseInFlight = false; userSpeaking = false; configured = false
    }

    private func connect(legacy: Bool) {
        let c = RealtimeClient(model: Settings.shared.realtimeModel, key: Settings.shared.openAIKey ?? "", legacy: legacy)
        c.onEvent = { [weak self] ev in Task { @MainActor in self?.handle(ev) } }
        c.onClosed = { [weak self] msg in Task { @MainActor in
            guard let self, self.isActive, self.client === c else { return }
            self.fail(msg ?? "Voice connection closed.")
        } }
        client = c
        configured = false
        c.connect()
    }

    private func tick() {
        guard isActive else { return }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        _ = notch.status("Voice mode · \(clock(seconds))", icon: "waveform", id: chipId)
        let idle = Date().timeIntervalSince(lastActivity)
        if configured, !responseInFlight, !userSpeaking, pendingConfirmation == nil, player?.isPlaying != true, idle > Self.silenceLimit {
            stop(reason: "silence")
        }
    }

    private func clock(_ s: Int) -> String { "\(s / 60):" + String(format: "%02d", s % 60) }

    // MARK: server events

    private func handle(_ ev: [String: Any]) {
        guard isActive, let type = ev["type"] as? String else { return }
        switch type {
        case "session.created":
            sendSessionUpdate(createResponse: pendingConfirmation == nil)
        case "session.updated":
            if !configured {
                configured = true
                client?.setAudioEnabled(true)
                lastActivity = Date()
                notch.model.phase = .listening
            }
        case "input_audio_buffer.speech_started":
            userSpeaking = true
            lastActivity = Date()
            interruptPlayback()
            notch.model.phase = .listening
        case "input_audio_buffer.speech_stopped":
            userSpeaking = false
            lastActivity = Date()
            if !responseInFlight && pendingConfirmation == nil { notch.model.phase = .thinking }
        case "conversation.item.input_audio_transcription.completed":
            if let t = (ev["transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                userTranscript(t)
            }
        case "response.created":
            responseInFlight = true
            responseCreatePending = false
            responseText = ""
            currentItemId = nil
            notch.clearResponse()
            player?.flush()
            lastActivity = Date()
        case "response.output_item.added":
            if let item = ev["item"] as? [String: Any], item["type"] as? String == "message", let id = item["id"] as? String {
                currentItemId = id
            }
        case "response.output_audio.delta", "response.audio.delta":
            if let id = ev["item_id"] as? String { currentItemId = id }
            if let b64 = ev["delta"] as? String, let pcm = Data(base64Encoded: b64) {
                voiceUsed = true
                player?.enqueue(pcm)
                if !notch.model.speaking { notch.model.speaking = true }
                if notch.model.phase != .responding { notch.model.phase = .responding }
            }
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            if let d = ev["delta"] as? String {
                responseText += d
                notch.appendResponse(d)
            }
        case "response.output_item.done":
            if let item = ev["item"] as? [String: Any], item["type"] as? String == "function_call",
               let name = item["name"] as? String, let callId = item["call_id"] as? String {
                let args = item["arguments"] as? String ?? "{}"
                enqueueFunctionCall(name: name, callId: callId, argsJSON: args)
            }
        case "response.done":
            responseInFlight = false
            lastActivity = Date()
            if let r = ev["response"] as? [String: Any] {
                if let usage = r["usage"] as? [String: Any] { Log.info("Realtime usage: " + JSON.stringify(usage)) }
                let status = r["status"] as? String ?? ""
                if status == "failed", let details = r["status_details"] as? [String: Any],
                   let err = details["error"] as? [String: Any], let msg = err["message"] as? String {
                    Log.warn("Realtime response failed: \(msg)")
                    notch.model.errorText = msg
                }
            }
            let text = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { History.shared.record(role: "assistant", text: text) }
            if responseCreatePending, pendingFunctionCalls == 0 { responseCreatePending = false; client?.send(["type": "response.create"]) }
            if player?.isPlaying != true, pendingFunctionCalls == 0 { notch.model.phase = .listening }
        case "error":
            serverError(ev["error"] as? [String: Any] ?? [:])
        default:
            break
        }
    }

    private func sendSessionUpdate(createResponse: Bool) {
        guard let c = client else { return }
        c.send(RealtimeClient.sessionUpdate(instructions: instructions, tools: toolDefs, voice: "cedar", legacy: c.legacy,
                                            createResponse: createResponse, includeVoice: !voiceUsed))
    }

    private func serverError(_ err: [String: Any]) {
        let message = err["message"] as? String ?? "Realtime error"
        let code = err["code"] as? String ?? ""
        let kind = err["type"] as? String ?? ""
        // The GA session shape was rejected: reconnect once with the beta header and flat shape.
        if !configured, !triedLegacy, client?.legacy == false {
            triedLegacy = true
            Log.warn("Realtime session.update rejected (\(message)); retrying with legacy session shape")
            client?.close(); client = nil
            connect(legacy: true)
            return
        }
        let benign = message.localizedCaseInsensitiveContains("truncat")
            || message.localizedCaseInsensitiveContains("no active response")
            || message.localizedCaseInsensitiveContains("already has an active response")
            || message.localizedCaseInsensitiveContains("cancellation failed")
            || message.localizedCaseInsensitiveContains("buffer too small")
        if benign { Log.warn("Realtime: \(message)"); return }
        Log.error("Realtime error [\(kind)/\(code)]: \(message)")
        if !configured || kind == "server_error" || code.contains("session") || code.contains("rate_limit") || message.contains("401") {
            fail(friendly(message))
        } else {
            notch.model.errorText = message
        }
    }

    private func friendly(_ m: String) -> String {
        if m.localizedCaseInsensitiveContains("api key") || m.contains("401") { return "OpenAI rejected the key. Check Settings → General → Model." }
        if m.localizedCaseInsensitiveContains("rate limit") { return "OpenAI rate limit. Try voice mode again in a moment." }
        return m
    }

    // MARK: playback

    private func interruptPlayback() {
        guard let p = player else { return }
        let playedMs = p.playedMs
        let wasPlaying = p.isPlaying
        p.flush()
        notch.model.speaking = false
        if wasPlaying, let itemId = currentItemId {
            client?.send(["type": "conversation.item.truncate", "item_id": itemId, "content_index": 0, "audio_end_ms": playedMs])
            currentItemId = nil
        }
    }

    private func playbackDrained() {
        guard isActive else { return }
        notch.model.speaking = false
        lastActivity = Date()
        if !responseInFlight, pendingFunctionCalls == 0, pendingConfirmation == nil { notch.model.phase = .listening }
    }

    // MARK: user transcripts

    private func userTranscript(_ text: String) {
        lastUserText = text
        lastActivity = Date()
        notch.model.transcript = text
        History.shared.record(role: "user", text: text)
        let s = text.lowercased().trimmingCharacters(in: .punctuationCharacters).trimmingCharacters(in: .whitespaces)
        if Self.stopPhrases.contains(where: { s == $0 || s.hasPrefix($0 + " ") || s.hasSuffix(" " + $0) || s.contains("stop voice mode") }) {
            stop(reason: "user said \"\(text)\"")
            return
        }
        if let pc = pendingConfirmation {
            if let d = QuickIntent.confirmDecision(text) { pc.resolve(d, nil) }
            else { pc.resolve(.cancel, text) }     // "make it 7:30": hand the words back to the model to retry with edits
        }
    }

    // MARK: tools

    private func enqueueFunctionCall(name: String, callId: String, argsJSON: String) {
        pendingFunctionCalls += 1
        lastActivity = Date()
        let previous = toolQueue
        toolQueue = Task { [weak self] in
            await previous?.value
            guard let self, self.isActive else { return }
            let output = await self.runTool(name: name, argsJSON: argsJSON)
            guard self.isActive else { return }
            self.client?.send(["type": "conversation.item.create",
                               "item": ["type": "function_call_output", "call_id": callId, "output": JSON.stringify(output)]])
            self.pendingFunctionCalls = max(0, self.pendingFunctionCalls - 1)
            self.lastActivity = Date()
            if self.pendingFunctionCalls == 0 {
                if self.responseInFlight { self.responseCreatePending = true }
                else { self.client?.send(["type": "response.create"]) }
            }
        }
    }

    private func runTool(name: String, argsJSON: String) async -> [String: Any] {
        guard let tool = ToolRegistry.shared.tool(name) else {
            return ["ok": false, "error": "Unknown tool \(name)"]
        }
        var args = JSON.parse(argsJSON)
        if let spec = tool.confirmation, Settings.shared.confirmActions {
            let (decision, spokenReply) = await confirm(spec, args: args)
            switch decision {
            case .cancel:
                if let words = spokenReply {
                    return ["ok": false, "cancelled": true,
                            "note": "User replied \"\(words)\" instead of confirming. Adjust the arguments accordingly and call the tool again, or stop if it was a refusal."]
                }
                return ["ok": false, "cancelled": true, "note": "User cancelled. Acknowledge briefly, do not retry."]
            case .confirm(let edited):
                for (k, v) in edited { args[k] = coerce(v, like: args[k], tool: tool, key: k) }
            }
        }
        let chip = notch.status(tool.statusLabel, icon: tool.statusIcon)
        let ctx = await makeContext()
        let result = await tool.run(args, ctx: ctx)
        notch.finishStatus(chip, ok: result.ok)
        for c in result.cards { notch.present(c) }
        return result.json
    }

    /// Cheap context: frontmost app. Full screenshot/selection read only for screen requests.
    private func makeContext() async -> ToolContext {
        let t = lastUserText.lowercased()
        let wantsScreen = ["screen", "this", "these", "here", "that", "selected", "looking at"].contains { t.contains($0) }
        if wantsScreen {
            let snap = await ContextBuilder.shared.build(turnId: UUID(), transcript: lastUserText)
            return ToolContext(turnId: snap.turnId, screenshotPath: snap.imagePaths.first, selectedText: snap.selectedText,
                               frontmostApp: snap.frontmostApp, frontmostBundleId: snap.frontmostBundleId, clipboard: snap.clipboard,
                               openCardTaskId: nil, attachments: snap.gestureImagePaths, transcript: lastUserText)
        }
        let app = NSWorkspace.shared.frontmostApplication
        return ToolContext(turnId: UUID(), screenshotPath: nil, selectedText: nil, frontmostApp: app?.localizedName,
                           frontmostBundleId: app?.bundleIdentifier, clipboard: nil, openCardTaskId: nil, attachments: [], transcript: lastUserText)
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

    /// Same card as AgentRuntime.confirm. While it is up, the server stops auto-creating responses so a spoken
    /// "yes" resolves the card instead of starting a model turn; the function output then drives the next response.
    private func confirm(_ spec: ConfirmationSpec, args: [String: Any]) async -> (ConfirmationCard.Decision, String?) {
        sendSessionUpdate(createResponse: false)
        let result: (ConfirmationCard.Decision, String?) = await withCheckedContinuation { cont in
            let id = UUID()
            var card = ConfirmationCard(id: id, icon: spec.icon, title: spec.title, subtitle: spec.subtitle?(args),
                                        fields: spec.fields.map { f in
                                            .init(id: f.key, label: f.label, kind: f.kind,
                                                  value: JSON.string(args[f.key]) ?? (args[f.key].map { JSON.stringify($0) } ?? ""), required: f.required)
                                        }, confirmLabel: spec.confirmLabel, destructive: spec.destructive)
            var resolved = false
            let finish: (ConfirmationCard.Decision, String?) -> Void = { [weak self] d, words in
                guard !resolved else { return }; resolved = true
                self?.pendingConfirmation = nil
                self?.notch.dismissCard(id)
                cont.resume(returning: (d, words))
            }
            card.onDecision = { finish($0, nil) }
            pendingConfirmation = (id, finish)
            notch.present(.confirmation(card), id: id)
            notch.model.phase = .listening
        }
        if isActive { sendSessionUpdate(createResponse: true) }
        return result
    }
}

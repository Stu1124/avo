import Foundation
import AVFoundation

/// Spoken replies. Buffers streamed text into sentences, synthesizes each (Gemini TTS, Apple fallback), plays in order.
@MainActor
final class Speech {
    static let shared = Speech()
    private var buffer = ""
    private var queue: [String] = []
    private var synthesizing = false
    private let player = AudioQueuePlayer()
    private let apple = AVSpeechSynthesizer()
    private var generation = 0

    var enabled: Bool { Settings.shared.speakReplies }
    /// Something is queued, synthesizing, or half-buffered: a new hold should silence it even though
    /// nothing is audible yet.
    var isBusy: Bool { synthesizing || !queue.isEmpty || !buffer.isEmpty }

    /// Streamed text delta from the model.
    func feed(_ delta: String) {
        guard enabled else { return }
        buffer += delta
        // Flush on sentence boundaries.
        while let r = buffer.range(of: #"[.!?]\s|\n"#, options: .regularExpression) {
            let sentence = String(buffer[..<r.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[r.upperBound...])
            enqueue(sentence)
        }
    }

    func flushSentence() {
        let s = buffer.trimmingCharacters(in: .whitespacesAndNewlines); buffer = ""
        if enabled { enqueue(s) }
    }

    func finish() { flushSentence() }

    /// Speak immediately (confirmation prompts), ahead of anything queued.
    func sayNow(_ text: String) {
        guard enabled else { return }
        let spoken = SpeechText.plain(text)
        guard spoken.count > 1 else { return }
        queue.insert(spoken, at: 0)
        pump()
    }

    func stop() {
        generation += 1
        buffer = ""; queue = []
        player.stop()
        apple.stopSpeaking(at: .immediate)
        NotchController.shared.model.speaking = false
    }

    /// Narration arrives as Markdown. Strip it here so neither TTS engine reads "asterisk asterisk".
    private func enqueue(_ s: String) {
        let spoken = SpeechText.plain(s)
        guard spoken.count > 1 else { return }
        // Cap queue to prevent unbounded growth if synthesis stalls.
        if queue.count >= 20 { queue.removeFirst() }
        queue.append(spoken); pump()
    }

    private func pump() {
        guard !synthesizing, !queue.isEmpty else { return }
        synthesizing = true
        let text = queue.removeFirst()
        let gen = generation
        Task {
            let audio = await TTS.synthesize(text)
            guard gen == generation else { synthesizing = false; return }
            if let a = audio {
                NotchController.shared.model.speaking = true
                player.play(a) { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        if self.queue.isEmpty { NotchController.shared.model.speaking = false }
                        self.synthesizing = false; self.pump()
                    }
                }
            } else {
                // Apple fallback: the default engine, and where a Gemini failure lands.
                Log.info("Spoken reply: Apple voice, \(text.count) chars")
                let u = AVSpeechUtterance(string: text)
                u.voice = AVSpeechSynthesisVoice(language: "en-GB") ?? AVSpeechSynthesisVoice(language: "en-US")
                u.rate = 0.5
                NotchController.shared.model.speaking = true
                apple.speak(u)
                try? await Task.sleep(nanoseconds: UInt64(Double(text.count) * 0.055 * 1e9))
                NotchController.shared.model.speaking = false
                synthesizing = false; pump()
            }
        }
    }
}

/// Text → PCM/WAV via Gemini TTS. Returns nil to trigger the Apple fallback, which is the default:
/// Gemini is used only when the user picks it as the engine and has a key.
enum TTS {
    struct Audio { var data: Data; var sampleRate: Double; var pcm16: Bool }

    @MainActor
    static func synthesize(_ text: String) async -> Audio? {
        let s = Settings.shared
        guard s.ttsEngine == "gemini", let key = s.geminiKey, !key.isEmpty else { return nil }
        let model = s.ttsModel
        let styled = s.ttsStyle.isEmpty ? text : "Say this \(s.ttsStyle): \(text)"
        let body: [String: Any] = [
            "contents": [["parts": [["text": styled]]]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": s.ttsVoice]]]
            ]
        ]
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = obj["candidates"] as? [[String: Any]],
              let parts = (cands.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]],
              let inline = parts.first?["inlineData"] as? [String: Any],
              let b64 = inline["data"] as? String, let pcm = Data(base64Encoded: b64) else {
            Log.warn("Gemini TTS failed: \(String(decoding: data.prefix(300), as: UTF8.self))")
            return nil
        }
        // mimeType like "audio/L16;codec=pcm;rate=24000"
        let mime = inline["mimeType"] as? String ?? "audio/L16;rate=24000"
        let declared = Double(mime.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.compactMap { $0.hasPrefix("rate=") ? String($0.dropFirst(5)) : nil }.first ?? "24000") ?? 24000
        // The rate comes off the wire, so it may be zero, negative, NaN or absurd. AVAudioFormat
        // rejects anything outside what the hardware can render, so clamp to a sane band first and
        // fall back to the Gemini default when the value is not a usable number at all.
        let rate = (declared.isFinite && declared >= 8_000 && declared <= 96_000) ? declared : 24_000
        if rate != declared { Log.warn("Gemini TTS: ignoring sample rate \(declared), using \(rate)") }
        return Audio(data: pcm, sampleRate: rate, pcm16: true)
    }
}

/// Plays raw PCM16 mono buffers back-to-back through AVAudioEngine.
final class AudioQueuePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var connectedRate: Double = 0

    func play(_ a: TTS.Audio, completion: @escaping () -> Void) {
        // Every exit path has to release the queue exactly once. The render callback and the
        // give-up paths below can both run — and stopping a node delivers its pending callbacks —
        // so route them all through one latch. Miss this and `Speech.synthesizing` sticks at true
        // and nothing is ever spoken again.
        let done = Once(completion)
        // AVAudioPlayerNode wants the standard Float32 non-interleaved format; convert the PCM16
        // payload on the way in. The rate reached us over the network, so the format may not exist.
        guard let format = AVAudioFormat(standardFormatWithSampleRate: a.sampleRate, channels: 1) else {
            Log.warn("Spoken reply: no output format for \(a.sampleRate) Hz")
            done.fire(); return
        }
        if connectedRate != a.sampleRate {
            if engine.isRunning { engine.stop() }
            if node.engine == nil { engine.attach(node) }
            engine.connect(node, to: engine.mainMixerNode, format: format)
            connectedRate = a.sampleRate
        }
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch {
                Log.warn("Spoken reply: output start failed (\(error.localizedDescription))")
                done.fire(); return
            }
        }
        let frames = a.data.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { done.fire(); return }
        buf.frameLength = AVAudioFrameCount(frames)
        let dst = buf.floatChannelData![0]
        a.data.withUnsafeBytes { raw in
            for i in 0..<frames { dst[i] = Float(raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)) / 32768 }
        }
        node.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in done.fire() }
        // The engine can be stopped between the start above and this call: a configuration change
        // (a new input device, the dictation engine warming up) resets it on another thread, and
        // AVAudioPlayerNode.play() raises an uncatchable NSException when its engine is not running.
        // Re-check right before starting the node, and restart once if needed.
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch {
                Log.warn("Spoken reply: output restart failed (\(error.localizedDescription))")
                node.stop(); node.reset(); done.fire(); return
            }
        }
        guard engine.isRunning else { node.stop(); node.reset(); done.fire(); return }
        if !node.isPlaying { node.play() }
    }

    /// Safe on a cold player: a node that was never attached has nothing to stop.
    func stop() {
        guard node.engine != nil else { return }
        node.stop(); node.reset()
    }
}

/// Runs a closure at most once, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let body: () -> Void

    init(_ body: @escaping () -> Void) { self.body = body }

    func fire() {
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        if first { body() }
    }
}

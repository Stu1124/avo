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

/// Markdown → speakable text. The model answers in light Markdown (bold, code spans, citation links);
/// spoken output should carry the words only. Log evidence: "**trendline**", "`#DIV/0!`" and "([]())" were sent verbatim.
enum SpeechText {
    static func plain(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"```[A-Za-z0-9_+-]*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "`", with: "")
        // [text](url) → text; a link with no text vanishes, as does the "( )" the model wraps citations in.
        t = t.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, with: "$2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<![A-Za-z0-9])(\*|_)(?=\S)(.+?)(?<=\S)\1(?![A-Za-z0-9])"#, with: "$2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^\s*>\s?"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"https?://[^\s)\]]+"#, with: "link", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let rate = Double(mime.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.compactMap { $0.hasPrefix("rate=") ? String($0.dropFirst(5)) : nil }.first ?? "24000") ?? 24000
        return Audio(data: pcm, sampleRate: rate, pcm16: true)
    }
}

/// Plays raw PCM16 mono buffers back-to-back through AVAudioEngine.
final class AudioQueuePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var connectedRate: Double = 0

    func play(_ a: TTS.Audio, completion: @escaping () -> Void) {
        // AVAudioPlayerNode wants the standard Float32 non-interleaved format; convert the PCM16 payload on the way in.
        let format = AVAudioFormat(standardFormatWithSampleRate: a.sampleRate, channels: 1)!
        if connectedRate != a.sampleRate {
            if engine.isRunning { engine.stop() }
            if node.engine == nil { engine.attach(node) }
            engine.connect(node, to: engine.mainMixerNode, format: format)
            connectedRate = a.sampleRate
        }
        if !engine.isRunning { engine.prepare(); try? engine.start() }
        let frames = a.data.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { completion(); return }
        buf.frameLength = AVAudioFrameCount(frames)
        let dst = buf.floatChannelData![0]
        a.data.withUnsafeBytes { raw in
            for i in 0..<frames { dst[i] = Float(raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)) / 32768 }
        }
        node.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in completion() }
        if !node.isPlaying { node.play() }
    }

    /// Safe on a cold player: a node that was never attached has nothing to stop.
    func stop() {
        guard node.engine != nil else { return }
        node.stop(); node.reset()
    }
}

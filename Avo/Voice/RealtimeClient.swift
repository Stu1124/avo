import Foundation

/// Thin WebSocket client for the OpenAI Realtime API. JSON in, JSON out; no session logic here.
/// `legacy == true` uses the beta header and the flat session shape (pcm16 / server_vad / response.audio.*).
final class RealtimeClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let legacy: Bool
    private let model: String
    private let key: String
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var audioEnabled = false
    private var closed = false

    /// Every server event, decoded. Called on a background queue.
    var onEvent: (([String: Any]) -> Void)?
    /// Socket ended. `nil` = clean close requested by us; otherwise a message to show.
    var onClosed: ((String?) -> Void)?

    init(model: String, key: String, legacy: Bool) {
        self.model = model; self.key = key; self.legacy = legacy
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func connect() {
        var comps = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        comps.queryItems = [URLQueryItem(name: "model", value: model)]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if legacy { req.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta") }
        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = 2 * 1024 * 1024
        task = t
        t.resume()
        receiveLoop()
    }

    func send(_ event: [String: Any]) {
        guard !isClosed else { return }
        let text = JSON.stringify(event)
        task?.send(.string(text)) { [weak self] err in
            if let err { self?.fail(err.localizedDescription) }
        }
    }

    /// Gate for mic chunks: only stream audio once the session is configured.
    func setAudioEnabled(_ on: Bool) { lock.lock(); audioEnabled = on; lock.unlock() }

    func appendAudio(_ pcm16: Data) {
        lock.lock(); let on = audioEnabled; lock.unlock()
        guard on else { return }
        send(["type": "input_audio_buffer.append", "audio": pcm16.base64EncodedString()])
    }

    func close() {
        lock.lock()
        let was = closed; closed = true
        lock.unlock()
        guard !was else { return }
        task?.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        task = nil
        onEvent = nil
        onClosed = nil
    }

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self, !self.isClosed else { return }
            switch result {
            case .success(let msg):
                let data: Data?
                switch msg {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: data = nil
                }
                if let d = data, let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                    self.onEvent?(obj)
                }
                self.receiveLoop()
            case .failure(let e):
                self.fail(e.localizedDescription)
            }
        }
    }

    private func fail(_ message: String) {
        lock.lock()
        let was = closed; closed = true
        lock.unlock()
        guard !was else { return }
        let cb = onClosed
        task?.cancel(with: .abnormalClosure, reason: nil)
        session.invalidateAndCancel()
        task = nil
        cb?(message)
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let why = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        fail("Voice connection closed (\(closeCode.rawValue))\(why.isEmpty ? "" : ": \(why)")")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { fail(error.localizedDescription) }
    }

    // MARK: session config

    /// Full session.update. `includeVoice` must be false after any audio has been produced (voice is immutable then).
    static func sessionUpdate(instructions: String, tools: [[String: Any]], voice: String, legacy: Bool,
                              createResponse: Bool, includeVoice: Bool) -> [String: Any] {
        let transcription: [String: Any] = ["model": "gpt-4o-mini-transcribe"]
        var s: [String: Any]
        if legacy {
            s = ["modalities": ["audio", "text"],
                 "instructions": instructions,
                 "input_audio_format": "pcm16",
                 "output_audio_format": "pcm16",
                 "input_audio_transcription": transcription,
                 "turn_detection": ["type": "server_vad", "create_response": createResponse, "interrupt_response": true],
                 "tools": tools.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") },
                 "tool_choice": "auto"]
            if includeVoice { s["voice"] = voice }
        } else {
            var output: [String: Any] = ["format": ["type": "audio/pcm", "rate": 24000]]
            if includeVoice { output["voice"] = voice }
            s = ["type": "realtime",
                 // NSDecimalNumber: a Double 0.8 serializes as 0.80000000000000004, which the API rejects.
                 "truncation": ["type": "retention_ratio", "retention_ratio": NSDecimalNumber(string: "0.8")],
                 "instructions": instructions,
                 "audio": ["input": ["format": ["type": "audio/pcm", "rate": 24000],
                                     "transcription": transcription,
                                     "turn_detection": ["type": "semantic_vad", "create_response": createResponse, "interrupt_response": true]],
                           "output": output],
                 "tools": tools.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") },
                 "tool_choice": "auto"]
        }
        return ["type": "session.update", "session": s]
    }
}

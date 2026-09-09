import Foundation
import AVFoundation
import Speech
import Combine

/// Published hands-free state for UI (collapsed-notch dot, settings status).
@MainActor
final class WakeWordState: ObservableObject {
    static let shared = WakeWordState()
    /// Mic open, listening for the wake phrase.
    @Published var active = false
    /// Wake phrase heard; capturing the command that follows.
    @Published var capturing = false
    /// Why the listener is not active (permission denied, model missing), for settings.
    @Published var problem: String?
}

/// Hands-free "Hey Avo": one continuous on-device SpeechAnalyzer session that only looks for the wake phrase in
/// volatile results. On a hit the same session keeps transcribing (no mic hand-off, no lost syllables); once the
/// transcript has been stable for 1.2 s the text after the wake phrase is posted as `avo.wake` and AvoApp runs the turn.
/// The session is closed while Avo is listening (fn), thinking, speaking, or in voice mode, and reopened when idle.
///
/// SpeechAnalyzer is macOS 26 only, so hands-free is unavailable below that; callers reach this type
/// only inside `if #available(macOS 26, *)` and Settings shows "Hands-free needs macOS 26." instead.
@available(macOS 26, *)
@MainActor
final class WakeWord {
    static let shared = WakeWord()
    static let notification = Notification.Name("avo.wake")

    private let state = WakeWordState.shared
    private var enabled = false
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var cachedFormat: AVAudioFormat?
    private var session = 0
    private var tapInstalled = false
    private var opening = false
    private var nextOpenAt = Date.distantPast
    private var sessionStartedAt = Date()
    private var finalized = ""
    private var volatile = ""
    private var level: Float = 0

    private enum Phase { case idle, capturing }
    private var phase: Phase = .idle
    private var utterance = ""
    private var utteranceTokens: [String] = []
    private var utteranceChangedAt = Date()
    private var captureStartedAt = Date()
    private var supervisor: Timer?

    private static let silence: TimeInterval = 1.2
    private static let noSpeechTimeout: TimeInterval = 6
    private static let maxUtterance: TimeInterval = 30
    private static let rotateAfter: TimeInterval = 10 * 60

    var isActive: Bool { state.active }

    // MARK: lifecycle

    func start() {
        guard !enabled else { return }
        enabled = true
        Log.info("WakeWord: enabled (phrase '\(Settings.shared.wakeWord)')")
        supervisor?.invalidate()
        supervisor = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task {
            let ok = await Transcriber.shared.requestPermissions()
            guard ok else {
                state.problem = "Microphone or Speech Recognition access is off."
                Log.warn("WakeWord: mic permission denied")
                return
            }
            state.problem = nil
            tick()
        }
    }

    func stop() {
        guard enabled else { return }
        enabled = false
        supervisor?.invalidate(); supervisor = nil
        if phase == .capturing { abortCapture(collapse: true) }
        closeSession()
        state.active = false
        Log.info("WakeWord: disabled")
    }

    func microphoneSelectionDidChange() {
        guard enabled else { return }
        closeSession()
        tick()
    }

    // MARK: supervisor

    /// Busy = someone else owns the mic or Avo is mid-turn; the wake session must not run then.
    private var busy: Bool {
        if AgentRuntime.shared.isRunning { return true }
        let m = NotchController.shared.model
        if m.speaking { return true }
        if VoiceModeSession.shared.isActive { return true }
        if phase == .idle, m.phase == .listening || m.phase == .thinking || m.phase == .responding { return true }
        return false
    }

    private func tick() {
        guard enabled else { return }
        if phase == .capturing { checkCapture(); return }
        if busy {
            if engine != nil { closeSession() }
            return
        }
        if engine == nil {
            if !opening, Date() >= nextOpenAt { Task { await openSession() } }
            return
        }
        if Date().timeIntervalSince(sessionStartedAt) > Self.rotateAfter || finalized.count > 4000 {
            // Bounded analyzer state: fresh session every 10 min of idle listening.
            closeSession()
            Task { await openSession() }
        }
    }

    // MARK: session

    private func openSession() async {
        guard enabled, engine == nil, !opening else { return }
        // Same trap as `Transcriber.prepare()`: `inputNode` below blocks the main actor for as long
        // as an unanswered microphone prompt is on screen. The supervisor timer runs every 0.3 s
        // from `start()`, so without this it can reach the input graph before the grant lands.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            nextOpenAt = Date().addingTimeInterval(2)
            return
        }
        opening = true
        defer { opening = false }
        session += 1
        let mine = session
        finalized = ""; volatile = ""; level = 0
        let engine = AVAudioEngine()
        let input = engine.inputNode
        do {
            if let name = try AudioInputDevice.useConfiguredMicrophone(for: input, preferredUID: Settings.shared.microphoneUID) {
                Log.info("WakeWord: selected input \(name)")
            }
        } catch {
            Log.warn("WakeWord: input selection failed (\(error.localizedDescription))")
        }
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            Log.warn("WakeWord: no usable audio input")
            nextOpenAt = Date().addingTimeInterval(10)
            return
        }
        do {
            let t = SpeechTranscriber(locale: Locale.current, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
            let a = SpeechAnalyzer(modules: [t])
            if cachedFormat == nil { cachedFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) }
            guard mine == session, enabled else { return }
            let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
            self.engine = engine; transcriber = t; analyzer = a; inputBuilder = builder
            analyzerFormat = cachedFormat
            converter = nil
            if let bf = cachedFormat, bf != hwFormat { converter = AVAudioConverter(from: hwFormat, to: bf) }
            resultsTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await result in t.results {
                        let s = String(result.text.characters)
                        let isFinal = result.isFinal
                        await MainActor.run {
                            guard mine == self.session else { return }
                            if isFinal { self.finalized += (self.finalized.isEmpty ? "" : " ") + s; self.volatile = "" }
                            else { self.volatile = s }
                            self.handleText()
                        }
                    }
                } catch {
                    if !(error is CancellationError) { Log.warn("WakeWord results ended: \(error.localizedDescription)") }
                }
            }
            try await a.start(inputSequence: stream)
            guard mine == session, enabled else { closeSession(); return }
            input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buf, _ in
                let measuredLevel = Self.measureLevel(buf)
                guard let captured = WakeAudioBuffer(copying: buf) else { return }
                Task { @MainActor [weak self] in
                    guard let self, mine == self.session else { return }
                    self.level = self.level * 0.6 + measuredLevel * 0.4
                    if self.phase == .capturing { NotchController.shared.updateTranscript(self.utterance, level: self.level) }
                    self.ingest(captured)
                }
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            sessionStartedAt = Date()
            state.active = true
            state.problem = nil
        } catch {
            Log.warn("WakeWord: session failed: \(error.localizedDescription)")
            closeSession()
            state.problem = "Speech model unavailable: \(error.localizedDescription)"
            nextOpenAt = Date().addingTimeInterval(8)
        }
    }

    private func closeSession() {
        session += 1
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine?.stop()
        inputBuilder?.finish()
        resultsTask?.cancel()
        let a = analyzer
        Task { await a?.cancelAndFinishNow() }
        engine = nil; analyzer = nil; transcriber = nil; inputBuilder = nil; converter = nil; resultsTask = nil
        finalized = ""; volatile = ""
        state.active = false
    }

    private func ingest(_ captured: WakeAudioBuffer) {
        let buf = captured.buffer
        if let conv = converter, let af = analyzerFormat {
            guard let out = AVAudioPCMBuffer(pcmFormat: af, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * af.sampleRate / buf.format.sampleRate) + 16) else { return }
            var err: NSError?
            var consumed = false
            conv.convert(to: out, error: &err) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return captured.buffer
            }
            if err == nil { inputBuilder?.yield(AnalyzerInput(buffer: out)) }
        } else {
            inputBuilder?.yield(AnalyzerInput(buffer: buf))
        }
    }

    private nonisolated static func measureLevel(_ buf: AVAudioPCMBuffer) -> Float {
        guard let ch = buf.floatChannelData?[0] else { return 0 }
        let n = Int(buf.frameLength)
        var sum: Float = 0
        for i in stride(from: 0, to: n, by: 8) { sum += ch[i] * ch[i] }
        let rms = sqrt(sum / Float(max(n / 8, 1)))
        return min(1, rms * 9)
    }

    // MARK: detection

    private var text: String { volatile.isEmpty ? finalized : (finalized.isEmpty ? volatile : finalized + " " + volatile) }

    private func handleText() {
        let full = text
        switch phase {
        case .idle:
            guard !busy, let end = WakePhrase.matchEnd(in: full, custom: Settings.shared.wakeWord) else { return }
            detected(remainder: WakePhrase.remainder(of: full, after: end))
        case .capturing:
            guard let end = WakePhrase.matchEnd(in: full, custom: Settings.shared.wakeWord) else { return }   // revision dropped the phrase: keep last utterance
            let u = WakePhrase.remainder(of: full, after: end)
            let toks = WakePhrase.tokens(u)
            if toks != utteranceTokens { utteranceTokens = toks; utteranceChangedAt = Date() }
            utterance = u
            NotchController.shared.updateTranscript(u, level: level)
        }
    }

    private func detected(remainder: String) {
        Log.info("WakeWord: heard wake phrase")
        phase = .capturing
        captureStartedAt = Date()
        utterance = remainder
        utteranceTokens = WakePhrase.tokens(remainder)
        utteranceChangedAt = Date()
        state.capturing = true
        Speech.shared.stop()
        NotchController.shared.beginListening()          // plays Sounds.listenStart, expands the notch
        NotchController.shared.updateTranscript(remainder, level: level)
    }

    private func checkCapture() {
        let m = NotchController.shared.model
        if !m.expanded || m.phase != .listening {
            // User dismissed (Escape / click outside) or another input path took over.
            abortCapture(collapse: false); return
        }
        let now = Date()
        if !utteranceTokens.isEmpty, now.timeIntervalSince(utteranceChangedAt) >= Self.silence { finishCapture(); return }
        if utteranceTokens.isEmpty, now.timeIntervalSince(captureStartedAt) >= Self.noSpeechTimeout { abortCapture(collapse: true); return }
        if now.timeIntervalSince(captureStartedAt) >= Self.maxUtterance { finishCapture() }
    }

    private func finishCapture() {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.info("WakeWord: utterance '\(text.prefix(120))'")
        phase = .idle
        state.capturing = false
        utterance = ""; utteranceTokens = []
        closeSession()
        NotificationCenter.default.post(name: Self.notification, object: nil, userInfo: ["text": text])
        nextOpenAt = Date().addingTimeInterval(0.5)
    }

    private func abortCapture(collapse: Bool) {
        Log.info("WakeWord: capture aborted")
        phase = .idle
        state.capturing = false
        utterance = ""; utteranceTokens = []
        closeSession()
        if collapse { NotchController.shared.collapse() }
        nextOpenAt = Date().addingTimeInterval(0.5)
    }
}

/// AVAudioEngine reuses tap buffers, so hands-free recognition owns a copy before hopping actors.
private final class WakeAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init?(copying source: AVAudioPCMBuffer) {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData,
                  byteCount <= Int(destinationBuffers[index].mDataByteSize) else { return nil }
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }
        buffer = copy
    }
}

/// Fuzzy wake-phrase matching on transcript text.
enum WakePhrase {
    private static let avoVariants: Set<String> = ["avo", "avvo", "arvo", "aevo", "aveo", "avow"]
    private static let prefixes: Set<String> = ["hey", "hay", "okay", "ok", "hi", "yo", "oi"]
    /// These are too common on their own; accept them only right after a prefix ("hey ava" ≈ "hey avo").
    private static let prefixedOnly: Set<String> = ["ava", "avon", "auto", "afo"]

    static func tokens(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’")).inverted).filter { !$0.isEmpty }
    }

    private static func words(_ s: String) -> [(String, Range<String.Index>)] {
        var out: [(String, Range<String.Index>)] = []
        s.enumerateSubstrings(in: s.startIndex..., options: [.byWords, .localized]) { sub, range, _, _ in
            if let sub, !sub.isEmpty { out.append((sub.lowercased(), range)) }
        }
        return out
    }

    /// End index (in `text`) of the last wake-phrase occurrence, or nil.
    static func matchEnd(in text: String, custom: String) -> String.Index? {
        let ws = words(text)
        guard !ws.isEmpty else { return nil }
        let customToks = tokens(custom)
        var customCore = customToks
        if let f = customCore.first, prefixes.contains(f) { customCore.removeFirst() }
        let customIsAvo = customCore.count == 1 && avoVariants.contains(customCore[0])
        var end: String.Index?
        for i in ws.indices {
            let w = ws[i].0
            let prevIsPrefix = i > 0 && prefixes.contains(ws[i - 1].0)
            if avoVariants.contains(w) || (prevIsPrefix && prefixedOnly.contains(w)) { end = ws[i].1.upperBound; continue }
            if !customIsAvo, !customCore.isEmpty, i + 1 >= customCore.count {
                let start = i + 1 - customCore.count
                if Array(ws[start...i].map { $0.0 }) == customCore { end = ws[i].1.upperBound }
            }
        }
        return end
    }

    static func remainder(of text: String, after end: String.Index) -> String {
        var s = String(text[end...])
        while let f = s.first, f.isPunctuation || f.isWhitespace { s.removeFirst() }
        return s
    }
}

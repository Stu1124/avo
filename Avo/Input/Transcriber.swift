import Foundation
import AVFoundation
import Speech

/// On-device short-form dictation with SpeechAnalyzer (macOS 26). Falls back to SFSpeechRecognizer on-device,
/// which is also the only path on macOS 15–25 because SpeechAnalyzer does not exist there.
@MainActor
final class Transcriber {
    static let shared = Transcriber()
    private var engine: AVAudioEngine?
    /// `AnalyzerBackend` on macOS 26+, nil below. Untyped so the property itself needs no availability.
    private let backend: AnyObject?
    private var resultsTask: Task<Void, Never>?
    private var preparedEngine: AVAudioEngine?
    /// True for the whole of one warm-up pass — model install, analyzer setup, and the graph build.
    /// It is what keeps "one warm-up at a time" true. It says nothing about who owns the engine.
    private var preparing = false
    /// True across the `buildEngine` hop and nowhere else. While it is set, `warmUpQueue` owns that
    /// engine outright and `preparedEngine` is nil: `AVAudioEngine` graph mutation is not thread-safe,
    /// so nothing on the main actor may touch it in that window. This, not `preparing`, is what a
    /// hold waits on — the model install ahead of the build is unbounded on a first run, and a hold
    /// arriving there must take the warm engine and start, not queue behind a download.
    private var buildingEngine = false
    /// The microphone the in-flight build is negotiating, so a selection change can tell "the user
    /// picked a different device" from "the user picked the one being built".
    private var buildingForUID: String?
    /// The warm-up in flight, queued or building. `start()` waits on it while `buildingEngine` is set,
    /// rather than building a second engine on the same device or taking the one being built.
    private var prepareTask: Task<Void, Never>?
    /// A microphone change that arrived while the graph build was in flight. That build is negotiating
    /// the previous device, so another warm-up runs as soon as it hands its engine back.
    private var rewarmAfterPrepare = false
    private var pending: [CapturedAudio] = []     // audio captured before the analyzer was ready
    private var ready = false
    private var tapInstalled = false
    private var discardEngineAfterStop = false
    private(set) var text = ""
    private var finalized = ""
    var onUpdate: ((String, Float) -> Void)?
    private var level: Float = 0

    // Legacy fallback
    private var sfRecognizer: SFSpeechRecognizer?
    private var sfRequest: SFSpeechAudioBufferRecognitionRequest?
    private var sfTask: SFSpeechRecognitionTask?
    /// Bumped by start/stop/cancel so a `start()` still awaiting setup aborts if the hold ended meanwhile.
    private var session = 0
    /// Unlike `session`, this remains active while stop() waits for final speech results.
    private var activeSession: Int?

    init() {
        if #available(macOS 26, *) { backend = AnalyzerBackend() } else { backend = nil }
    }

    @available(macOS 26, *)
    private var analyzerBackend: AnalyzerBackend? { backend as? AnalyzerBackend }

    /// Set once by `applicationDidFinishLaunching`. Warming the audio graph starts real work with
    /// Core Audio (off the main actor, but still work), so only the real app does it: verification
    /// and UI-render modes run headless, where nothing will ever hold the talk key.
    var warmUpEnabled = false

    var permissionsGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized &&
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    func microphoneSelectionDidChange() {
        if activeSession != nil {
            preparedEngine = nil
            discardEngineAfterStop = true
            return
        }
        if buildingEngine {
            // A build is in flight for the device it captured, and it owns that engine until it hands
            // it back. Touching it here would mutate a graph another thread is configuring, so the
            // new selection is recorded and warmed once this one finishes — unless it names the very
            // device being built, which also clears a flag left by an earlier change away from it.
            // Discarding a just-built engine because its device was picked again is pure waste.
            rewarmAfterPrepare = buildingForUID != Settings.shared.microphoneUID
            return
        }
        preparedEngine = nil
        warmUp()   // a warm-up that has not reached its build hop re-reads the UID there; one that has, re-runs
    }

    /// Microphone access just changed. Runs the warm-up skipped while access was pending, so the
    /// first hold after the grant is as fast as every later one.
    func permissionDidChange() {
        guard warmUpEnabled, preparedEngine == nil, activeSession == nil, prepareTask == nil,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        Log.info("Transcriber: microphone authorized, warming up input")
        warmUp()
    }

    /// Starts the one in-flight warm-up, or notes that another is wanted after it. Every caller goes
    /// through here: `prepareTask` is what makes "exactly one builder at a time" true, and what a
    /// hold waits on.
    func warmUp() {
        guard prepareTask == nil else { rewarmAfterPrepare = true; return }
        prepareTask = Task { [weak self] in
            guard let self else { return }
            await self.prepare()
            self.prepareTask = nil
            guard self.rewarmAfterPrepare else { return }
            self.rewarmAfterPrepare = false
            self.preparedEngine = nil          // built for a device the user has since changed
            self.warmUp()
        }
    }

#if DEBUG
    /// Test seams. `tests/` cannot reach a private field, and the interleaving harness has to be able
    /// to say that a microphone change during a build was recorded rather than swallowed, and that
    /// the window a hold waits on is the graph build alone and not the model install before it.
    var debugRewarmPending: Bool { rewarmAfterPrepare }
    var debugBuildingEngine: Bool { buildingEngine }
    var debugPreparing: Bool { preparing }
#endif

    func requestPermissions() async -> Bool {
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
        Log.info("Permissions: mic=\(mic) speech=\(speech)")
        return mic && speech
    }

    /// One warm-up pass. Private on purpose: `warmUp()` is the entry point, because only it keeps
    /// `prepareTask` honest, and that task is the whole of the exclusion between this and `start()`.
    private func prepare() async {
        guard warmUpEnabled, !preparing, activeSession == nil else { return }
        // A fresh install has not answered the microphone prompt yet, and `AVAudioEngine.inputNode`
        // blocks its caller until that prompt is answered (measured 88 s, and 510 s once). The
        // build now happens on `warmUpQueue`, so that no longer freezes the notch — but a blocked
        // warm-up thread is still pointless. Skip it until access exists: `permissionDidChange()`
        // runs it the moment onboarding or Settings sees the grant, and `start()` builds an engine
        // of its own, with a deadline, if the first hold gets there first.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            Log.info("Transcriber: microphone not authorized yet, deferring input warm-up")
            return
        }
        preparing = true
        defer { preparing = false }

        if #available(macOS 26, *), let b = analyzerBackend {
            // Make sure the on-device model for the current locale is installed and the analyzer is
            // configured. None of that touches the audio graph, so the warm engine stays on the main
            // actor's books for the whole of it: a hold arriving during a first-run model download
            // takes that engine and starts, rather than waiting on a builder that is not building.
            guard let prewarmed = await b.prewarm() else { return }
            // That download can take minutes, and a hold may have started and be running now. It owns
            // the engine; building a second one behind its back would be waste at best. `stop()`
            // warms again, so nothing is lost by standing down here.
            guard activeSession == nil else { return }
            // Configure and prepare Avo's selected input graph, but never start it while idle. With
            // the built-in default this stays fast without switching AirPods to headset mode.
            guard let engine = await buildWarmEngine() else { return }
            b.commitPrewarm(prewarmed)
            // Handed back even if a hold started meanwhile: that hold is waiting on this task
            // precisely so it can use this engine instead of building a second one.
            preparedEngine = engine
            Log.info("Transcriber: analyzer prewarmed without opening microphone")
        } else {
            guard let engine = await buildWarmEngine() else { return }
            preparedEngine = engine
            Log.info("Transcriber: input prepared without opening microphone")
        }
    }

    /// The one hop that hands an engine to `warmUpQueue`, and the only window in which the main actor
    /// may not touch it. Everything that makes that ownership true is here: the engine leaves
    /// `preparedEngine` and `buildingEngine` goes up with no `await` between them, so there is no
    /// instant at which the graph is both on the books and under construction.
    private func buildWarmEngine() async -> AVAudioEngine? {
        let uid = Settings.shared.microphoneUID
        let reuse = preparedEngine
        preparedEngine = nil
        buildingEngine = true
        buildingForUID = uid
        defer { buildingEngine = false; buildingForUID = nil }
        return await Self.buildEngine(reusing: reuse, microphoneUID: uid).engine
    }

    /// Carries one engine across the queue hop. `AVAudioEngine` is not Sendable, and this is not a
    /// claim that it is: the queue is finished with the engine before the main actor is handed it,
    /// and only one side ever holds it.
    struct PreparedGraph: @unchecked Sendable { let engine: AVAudioEngine? }

    /// The queue that owns every warm-up touch of the audio graph. `AVAudioEngine.inputNode` blocks
    /// its caller until Core Audio (and, on a fresh install, the microphone prompt) is settled — a
    /// launch log has shown 510 s — so the main actor must never be that caller.
    private nonisolated static let warmUpQueue = DispatchQueue(label: "app.avo.mac.audio-warmup", qos: .userInitiated)

    /// Builds the input graph off the main actor and hands the finished engine back.
    private nonisolated static func buildEngine(reusing existing: AVAudioEngine?, microphoneUID: String) async -> PreparedGraph {
        let carried = PreparedGraph(engine: existing)
        return await withCheckedContinuation { (cont: CheckedContinuation<PreparedGraph, Never>) in
            warmUpQueue.async {
                cont.resume(returning: PreparedGraph(engine: makeEngine(reusing: carried.engine, microphoneUID: microphoneUID)))
            }
        }
    }

    /// Negotiates the configured microphone and prepares (but never starts) the audio graph.
    /// Runs on `warmUpQueue`; nothing here may be called from the main actor.
    private nonisolated static func makeEngine(reusing existing: AVAudioEngine?, microphoneUID: String) -> AVAudioEngine? {
        // `inputNode` is the call that blocks while a microphone prompt is unanswered. Log the
        // thread on the way in and the duration on the way out, so "the main actor was never parked
        // here" and "only ever one builder" are things the log shows rather than the code asserts:
        // an unmatched "reaching" line is a build still holding the graph.
        let startedAt = CFAbsoluteTimeGetCurrent()
        Log.info("Transcriber: reaching the input graph (mainThread=\(Thread.isMainThread))")
        let engine = existing ?? AVAudioEngine()
        let input = engine.inputNode
        Log.info("Transcriber: input graph reached in \(Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000))ms (mainThread=\(Thread.isMainThread))")
        do {
            if let name = try AudioInputDevice.useConfiguredMicrophone(for: input, preferredUID: microphoneUID) {
                Log.info("Transcriber: prepared input \(name)")
            }
        } catch {
            Log.warn("Transcriber: input selection failed (\(error.localizedDescription))")
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return nil }
        engine.prepare()
        return engine
    }

    func start() async -> Bool {
        let startedAt = CFAbsoluteTimeGetCurrent()
        tearDownCurrentCapture()
        session += 1
        let mine = session
        activeSession = mine
        text = ""; finalized = ""; level = 0; pending = []; ready = false
        // A warm-up may be building the graph right now, and while it is (`buildingEngine`), it owns
        // that engine: the hold neither takes it nor builds a rival one, it waits. Bounded, because
        // the build can be parked on an unanswered microphone prompt for minutes and a hold must not
        // hang behind it. The rest of a warm-up — installing the on-device model, configuring the
        // analyzer — never touches the graph, so a hold that lands there waits for nothing: the warm
        // engine is still on the books below and this hold starts on it. A warm-up that is only
        // queued needs no wait either: `activeSession` is already set, so it will find a hold in
        // progress and stand down without touching the graph.
        if buildingEngine {
            Log.info("Transcriber: hold arrived during the graph build; waiting for the prepared engine")
            let deadline = CFAbsoluteTimeGetCurrent() + 3
            while buildingEngine, let inFlight = prepareTask {
                let left = deadline - CFAbsoluteTimeGetCurrent()
                guard left > 0 else { break }
                _ = try? await withTimeout(seconds: left) { await inFlight.value }
                guard session == mine, activeSession == mine else { return false }
            }
            guard !buildingEngine else {
                Log.warn("Transcriber: warm-up still holds the audio graph after 3s; dropping this hold")
                activeSession = nil
                return false
            }
            Log.info("Transcriber: graph build finished in \(Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000))ms (engineReady=\(preparedEngine != nil))")
        }
        // A prepared engine has negotiated the built-in device but has never started audio I/O.
        let warmEngine = preparedEngine != nil
        let readyEngine: AVAudioEngine
        if let prepared = preparedEngine {
            readyEngine = prepared
        } else {
            // Nothing was warmed: the first hold after a fresh grant, or a device change mid-hold.
            // Building the graph blocks its thread for as long as Core Audio wants, so it happens
            // off the main actor, and the hold gives up rather than freezing the UI behind it.
            let uid = Settings.shared.microphoneUID
            let built = try? await withTimeout(seconds: 3) { await Self.buildEngine(reusing: nil, microphoneUID: uid) }
            guard session == mine, activeSession == mine else { return false }
            guard let engine = built?.engine else {
                Log.warn("Transcriber: audio graph was not ready within 3s (\(built == nil ? "timed out" : "no usable input")); dropping this hold")
                activeSession = nil
                return false
            }
            readyEngine = engine
        }
        let engine = readyEngine
        preparedEngine = nil
        self.engine = engine
        let input = engine.inputNode
        do {
            if let name = try AudioInputDevice.useConfiguredMicrophone(for: input, preferredUID: Settings.shared.microphoneUID), !warmEngine {
                Log.info("Transcriber: selected input \(name)")
            }
        } catch {
            Log.warn("Transcriber: input selection failed (\(error.localizedDescription))")
        }
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            Log.warn("Transcriber: no usable audio input (\(hwFormat))")
            self.engine = nil
            activeSession = nil
            return false
        }
        // 1. Start capturing immediately so the first syllable is never lost; buffers queue until the analyzer is up.
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buf, _ in
            let measuredLevel = Self.measureLevel(buf)
            guard let captured = CapturedAudio(copying: buf) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.activeSession == mine else { return }
                self.level = self.level * 0.6 + measuredLevel * 0.4
                self.onUpdate?(self.text, self.level)
                self.ingest(captured)
            }
        }
        tapInstalled = true
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            Log.error("Transcriber: engine start failed \(error.localizedDescription)")
            if activeSession == mine { self.engine = nil; activeSession = nil }
            return false
        }
        Log.info("Transcriber: capture started in \(Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000))ms (enginePrepared=\(warmEngine))")
        // 2. Start a preconfigured SpeechAnalyzer. A fresh one is only needed when the user
        // talks before launch prewarming finishes or immediately starts another recording.
        var analyzerRunning = false
        if #available(macOS 26, *), let b = analyzerBackend {
            do {
                guard let started = try await b.start(
                    hwFormat: hwFormat,
                    isCurrent: { [weak self] in self?.session == mine && self?.activeSession == mine },
                    onText: { [weak self] s, isFinal in
                        guard let self, self.activeSession == mine else { return }
                        if isFinal { self.finalized += (self.finalized.isEmpty ? "" : " ") + s; self.text = self.finalized }
                        else { self.text = self.finalized.isEmpty ? s : self.finalized + " " + s }
                        self.onUpdate?(self.text, self.level)
                    }
                ) else { engine.stop(); return false }
                resultsTask = started.resultsTask
                guard mine == session, activeSession == mine else { engine.stop(); return false }
                ready = true
                let queued = pending; pending = []
                for b in queued { ingest(b) }
                Log.info("Transcriber: analyzer ready in \(Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000))ms (prewarmed=\(started.prewarmed))")
                analyzerRunning = true
            } catch {
                Log.warn("SpeechAnalyzer unavailable (\(error.localizedDescription)); using SFSpeechRecognizer")
                guard mine == session, activeSession == mine else { engine.stop(); return false }
                resultsTask?.cancel()
                resultsTask = nil
                b.reset(cancelling: false)
            }
        }
        if !analyzerRunning {
            startLegacy(engine: engine, format: hwFormat, session: mine)
            ready = true
            let queued = pending; pending = []
            for b in queued { sfRequest?.append(b.buffer) }
        }
        return activeSession == mine && engine.isRunning
    }

    /// Route one captured buffer to whichever recognizer is active (or queue it until one is).
    private func ingest(_ captured: CapturedAudio) {
        let buf = captured.buffer
        if !ready { if pending.count < 400 { pending.append(captured) }; return }
        if let req = sfRequest { req.append(buf); return }
        if #available(macOS 26, *), let b = analyzerBackend { b.yield(captured) }
    }

    private nonisolated static func measureLevel(_ buf: AVAudioPCMBuffer) -> Float {
        guard let ch = buf.floatChannelData?[0] else { return 0 }
        let n = Int(buf.frameLength)
        var sum: Float = 0
        for i in stride(from: 0, to: n, by: 4) { sum += ch[i] * ch[i] }
        let rms = sqrt(sum / Float(max(n / 4, 1)))
        return min(1, rms * 9)
    }

    private func startLegacy(engine: AVAudioEngine, format: AVAudioFormat, session mine: Int) {
        let r = SFSpeechRecognizer(locale: Locale.current)
        guard let r else {
            // Below macOS 26 this is the only dictation path, so a silent failure here looks like a
            // microphone that hears nothing. Name the locale: SFSpeechRecognizer returns nil for a
            // locale it has no recognizer for.
            Log.warn("Transcriber: SFSpeechRecognizer unavailable for locale \(Locale.current.identifier); dictation will produce no text")
            return
        }
        if !r.isAvailable {
            Log.warn("Transcriber: SFSpeechRecognizer for \(Locale.current.identifier) is not available right now; dictation may produce no text")
        }
        r.supportsOnDeviceRecognition = true
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = r.supportsOnDeviceRecognition
        req.addsPunctuation = true
        req.taskHint = .dictation
        req.contextualStrings = Settings.shared.dictationTerms
        sfRecognizer = r; sfRequest = req
        sfTask = r.recognitionTask(with: req) { [weak self] res, _ in
            guard let self, let res else { return }
            Task { @MainActor in
                guard self.activeSession == mine else { return }
                self.text = res.bestTranscription.formattedString
                self.onUpdate?(self.text, self.level)
            }
        }
    }

    /// Stops capture; waits briefly for the final result.
    func stop() async -> String {
        session += 1
        guard let stoppingSession = activeSession else { return "" }
        let stoppingEngine = engine
        let stoppingRequest = sfRequest
        let stoppingResultsTask = resultsTask
        if tapInstalled {
            stoppingEngine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        stoppingEngine?.stop()
        var finalizingAnalyzer = false
        if #available(macOS 26, *), let b = analyzerBackend { finalizingAnalyzer = b.finishInput() }
        stoppingRequest?.endAudio()
        if finalizingAnalyzer, #available(macOS 26, *), let b = analyzerBackend {
            await b.finalizeFinishingAnalyzer()
            // Let the results loop deliver the final segment before we read `text`.
            if let rt = stoppingResultsTask { _ = try? await withTimeout(seconds: 0.3) { await rt.value } }
        } else {
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        stoppingResultsTask?.cancel()
        guard activeSession == stoppingSession else { return "" }
        sfTask?.cancel()
        let out = text
        engine = nil; resultsTask = nil
        if #available(macOS 26, *), let b = analyzerBackend { b.reset(cancelling: false) }
        sfRecognizer = nil; sfRequest = nil; sfTask = nil
        pending = []; ready = false
        activeSession = nil
        if let stoppingEngine, !discardEngineAfterStop {
            stoppingEngine.reset()
            stoppingEngine.prepare()
            preparedEngine = stoppingEngine
        }
        discardEngineAfterStop = false
        warmUp()
        return out
    }

    func cancel() {
        session += 1
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine?.stop()
        resultsTask?.cancel(); sfTask?.cancel()
        // `reset(cancelling:)` captures the analyzer before clearing it: the cancel Task runs
        // after this method, when the backend's own reference is already nil.
        if #available(macOS 26, *), let b = analyzerBackend { b.reset(cancelling: true) }
        let stoppedEngine = engine
        engine = nil; resultsTask = nil
        sfRecognizer = nil; sfRequest = nil; sfTask = nil
        pending = []; ready = false
        activeSession = nil
        text = ""
        if let stoppedEngine, !discardEngineAfterStop {
            stoppedEngine.reset()
            stoppedEngine.prepare()
            preparedEngine = stoppedEngine
        }
        discardEngineAfterStop = false
        warmUp()
    }

    private func tearDownCurrentCapture() {
        if let engine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
            engine.stop()
        }
        resultsTask?.cancel()
        sfTask?.cancel()
        if #available(macOS 26, *), let b = analyzerBackend { b.reset(cancelling: true) }
        engine = nil; resultsTask = nil
        sfRecognizer = nil; sfRequest = nil; sfTask = nil
        pending = []; ready = false
        activeSession = nil
    }
}

/// Everything that only exists on macOS 26: the SpeechAnalyzer session, its dictation module,
/// the analyzer input stream, and the format conversion feeding it. `Transcriber` holds one of
/// these behind `AnyObject` and reaches it only inside `if #available(macOS 26, *)`.
@available(macOS 26, *)
@MainActor
private final class AnalyzerBackend {
    /// A configured analyzer waiting for the next hold, produced by `prewarm()`.
    struct Prewarmed {
        let transcriber: DictationTranscriber
        let analyzer: SpeechAnalyzer
        let format: AVAudioFormat?
    }

    /// A live analyzer session. `prewarmed` only feeds the timing log line.
    struct Started {
        let resultsTask: Task<Void, Never>
        let prewarmed: Bool
    }

    private var analyzer: SpeechAnalyzer?
    private var transcriber: DictationTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var cachedFormat: AVAudioFormat?
    private var preparedAnalyzer: SpeechAnalyzer?
    private var preparedTranscriber: DictationTranscriber?
    private var preparedAnalyzerFormat: AVAudioFormat?
    /// The analyzer captured by `finishInput()`, held across the finalize await.
    private var finishing: SpeechAnalyzer?

    /// Installs the on-device model for the current locale and configures a spare analyzer.
    func prewarm() async -> Prewarmed? {
        let locale = Locale.current
        let t = makeTranscriber(locale: locale)
        if let req = try? await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try? await req.downloadAndInstall()
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
        let analyzer = SpeechAnalyzer(modules: [t])
        do {
            try await configure(analyzer)
        } catch {
            Log.warn("Transcriber: analyzer prewarm failed (\(error.localizedDescription))")
            return nil
        }
        return Prewarmed(transcriber: t, analyzer: analyzer, format: format)
    }

    func commitPrewarm(_ p: Prewarmed) {
        cachedFormat = p.format
        preparedAnalyzerFormat = p.format
        preparedTranscriber = p.transcriber
        preparedAnalyzer = p.analyzer
    }

    /// Starts an analyzer session over a fresh input stream. Returns nil when the hold ended
    /// while setting up; throws when the analyzer itself is unavailable.
    func start(hwFormat: AVAudioFormat,
               isCurrent: @escaping @MainActor () -> Bool,
               onText: @escaping @MainActor (String, Bool) -> Void) async throws -> Started? {
        let prewarmed = preparedAnalyzer != nil && preparedTranscriber != nil
        let t: DictationTranscriber
        let a: SpeechAnalyzer
        if let preparedTranscriber, let preparedAnalyzer {
            t = preparedTranscriber
            a = preparedAnalyzer
            self.preparedTranscriber = nil
            self.preparedAnalyzer = nil
        } else {
            t = makeTranscriber(locale: Locale.current)
            a = SpeechAnalyzer(modules: [t])
            try await configure(a)
        }
        transcriber = t; analyzer = a
        var bestFormat = preparedAnalyzerFormat ?? cachedFormat
        preparedAnalyzerFormat = nil
        if bestFormat == nil { bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) }
        guard isCurrent() else { return nil }
        analyzerFormat = bestFormat
        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = builder
        if let bf = bestFormat, bf != hwFormat { converter = AVAudioConverter(from: hwFormat, to: bf) }
        let resultsTask = Task {
            do {
                for try await result in t.results {
                    let s = String(result.text.characters)
                    let isFinal = result.isFinal
                    await MainActor.run { onText(s, isFinal) }
                }
            } catch { Log.warn("Transcriber results ended: \(error.localizedDescription)") }
        }
        do {
            try await a.start(inputSequence: stream)
        } catch {
            resultsTask.cancel()
            throw error
        }
        guard isCurrent() else { resultsTask.cancel(); return nil }
        return Started(resultsTask: resultsTask, prewarmed: prewarmed)
    }

    /// Converts to the analyzer's format when needed and hands one buffer to the live session.
    func yield(_ captured: CapturedAudio) {
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

    /// Ends the input stream. Returns true when an analyzer session is waiting to be finalized.
    func finishInput() -> Bool {
        inputBuilder?.finish()
        finishing = analyzer
        return finishing != nil
    }

    func finalizeFinishingAnalyzer() async {
        guard let a = finishing else { return }
        finishing = nil
        try? await withTimeout(seconds: 1.2) { try await a.finalizeAndFinishThroughEndOfInput() }
    }

    /// Clears the live session. `cancelling` also tells the analyzer to drop in-flight audio.
    func reset(cancelling: Bool) {
        inputBuilder?.finish()
        if cancelling {
            let a = analyzer
            Task { await a?.cancelAndFinishNow() }
        }
        analyzer = nil; transcriber = nil; inputBuilder = nil; converter = nil; analyzerFormat = nil
        finishing = nil
    }

    private func makeTranscriber(locale: Locale) -> DictationTranscriber {
        let preset = DictationTranscriber.Preset.progressiveShortDictation
        var contentHints = preset.contentHints
        switch Settings.shared.dictationProfile {
        case "farField": contentHints.insert(.farField)
        case "speechVariation": contentHints.insert(.atypicalSpeech)
        default: break
        }
        return DictationTranscriber(
            locale: locale,
            contentHints: contentHints,
            transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions,
            attributeOptions: preset.attributeOptions
        )
    }

    private func configure(_ analyzer: SpeechAnalyzer) async throws {
        let context = AnalysisContext()
        context.contextualStrings[.general] = Settings.shared.dictationTerms
        try await analyzer.setContext(context)
    }
}

/// Audio-engine tap buffers are reused by AVFAudio. Copy before crossing into a Task.
private final class CapturedAudio: @unchecked Sendable {
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

/// Runs `op` and returns its value, or throws CancellationError once `seconds` elapse.
/// Returns at the deadline even if `op` ignores cancellation (a task group would wait for it).
func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    let state = TimeoutState()
    return try await withCheckedThrowingContinuation { cont in
        let work = Task {
            do { let v = try await op(); if state.claim() { cont.resume(returning: v) } }
            catch { if state.claim() { cont.resume(throwing: error) } }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9))
            if state.claim() { work.cancel(); cont.resume(throwing: CancellationError()) }
        }
    }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if claimed { return false }; claimed = true; return true }
}

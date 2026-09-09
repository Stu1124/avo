import AVFoundation
import Foundation

/// Tiny synthesized UI sounds. No assets, no latency, tasteful: short sine partials with fast decay.
final class Sounds: @unchecked Sendable {
    static let shared = Sounds()
    private let queue = DispatchQueue(label: "app.avo.mac.sounds", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private var cache: [String: AVAudioPCMBuffer] = [:]
    private var scheduledBuffers = 0

    private enum Graph { case cold, building, ready }
    private var graph = Graph.cold

    enum Cue: String { case listenStart, listenEnd, card, done, error, tick }

    /// Deliberately empty. Building the AVAudioEngine graph can spin a nested run loop inside Core Audio,
    /// and a hotkey or debug action delivered from that loop re-entered `Sounds.shared` while its
    /// `dispatch_once` initializer was still on the stack (SIGTRAP, 2026-09-03). The graph is built lazily
    /// instead, where re-entry is a harmless dropped cue rather than a trap.
    private init() {}

    /// Attaches and connects the player once. Returns false when called re-entrantly mid-build.
    private func ensureGraph() -> Bool {
        switch graph {
        case .ready: return true
        case .building: return false
        case .cold:
            graph = .building
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0.55
            graph = .ready
            return true
        }
    }

    /// Builds and caches the tiny cues without starting audio I/O. A continuously running silent
    /// output graph can contend with music/video playback and hold a Bluetooth output device open.
    @MainActor
    func prepare() {
        guard Settings.shared.soundsEnabled else { return }
        queue.async { [weak self] in self?.prepareNow() }
    }

    private func prepareNow() {
        guard ensureGraph() else { return }
        for cue in [Cue.listenStart, .listenEnd] where cache[cue.rawValue] == nil {
            cache[cue.rawValue] = render(cue)
        }
    }

    private var configObserver: NSObjectProtocol?

    private func observeConfiguration() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in self?.configurationChanged() }
        }
    }

    @MainActor
    func play(_ cue: Cue) {
        guard Settings.shared.soundsEnabled else { return }
        queue.async { [weak self] in self?.playNow(cue) }
    }

    private func playNow(_ cue: Cue) {
        guard ensureGraph() else { return }
        observeConfiguration()
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                Log.warn("Sounds: output start failed (\(error.localizedDescription))")
                return
            }
        }
        let buf = cache[cue.rawValue] ?? render(cue)
        cache[cue.rawValue] = buf
        scheduledBuffers += 1
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in self?.bufferFinished() }
        }
        // The engine can be stopped between the start above and this call: a configuration change
        // (a new input device, the dictation engine warming up) resets it on another thread, and
        // AVAudioPlayerNode.play() raises an uncatchable NSException when its engine is not running.
        // Re-check right before starting the node, and restart once if needed.
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch {
                Log.warn("Sounds: output restart failed (\(error.localizedDescription))"); return
            }
        }
        guard engine.isRunning else { return }
        if !player.isPlaying { player.play() }
    }

    /// The output graph was reset underneath us. Drop what is queued so the next cue starts clean.
    private func configurationChanged() {
        scheduledBuffers = 0
        player.stop()
        engine.stop()
    }

    private func bufferFinished() {
        scheduledBuffers = max(0, scheduledBuffers - 1)
        guard scheduledBuffers == 0 else { return }
        player.stop()
        engine.stop()
    }

    private func render(_ cue: Cue) -> AVAudioPCMBuffer {
        // (frequency, start, duration, gain) partials
        let notes: [(Double, Double, Double, Double)]
        switch cue {
        case .listenStart: notes = [(660, 0, 0.09, 0.5), (990, 0.04, 0.10, 0.35)]
        case .listenEnd:   notes = [(990, 0, 0.07, 0.4), (660, 0.04, 0.10, 0.35)]
        case .card:        notes = [(523.25, 0, 0.12, 0.35), (783.99, 0.08, 0.16, 0.3)]
        case .done:        notes = [(587.33, 0, 0.10, 0.3), (880, 0.07, 0.18, 0.28)]
        case .error:       notes = [(196, 0, 0.16, 0.45), (185, 0.02, 0.18, 0.25)]
        case .tick:        notes = [(1400, 0, 0.03, 0.25)]
        }
        let total = notes.map { $0.1 + $0.2 }.max()! + 0.05
        let n = AVAudioFrameCount(total * format.sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        buf.frameLength = n
        let p = buf.floatChannelData![0]
        for i in 0..<Int(n) {
            let t = Double(i) / format.sampleRate
            var v = 0.0
            for (f, s, d, g) in notes where t >= s && t < s + d {
                let lt = (t - s) / d
                let env = min(1, lt * 40) * pow(1 - lt, 2.2)
                v += sin(2 * .pi * f * (t - s)) * env * g
                v += sin(2 * .pi * f * 2 * (t - s)) * env * g * 0.12
            }
            p[i] = Float(tanh(v))
        }
        return buf
    }
}

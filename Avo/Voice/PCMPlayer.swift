import Foundation
import AVFoundation

/// Plays 24 kHz PCM16 mono chunks back-to-back through AVAudioEngine (converted to Float32 on enqueue).
/// Tracks how many milliseconds of the current response have actually been rendered, for `conversation.item.truncate`.
final class PCMPlayer: @unchecked Sendable {
    static let sampleRate: Double = 24_000

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    private let lock = NSLock()
    private var scheduledFrames: Int64 = 0
    private var outstanding = 0
    private var generation = 0
    private var started = false

    /// Called on the audio completion thread once every scheduled buffer has been rendered.
    var onDrained: (() -> Void)?

    func start() throws {
        guard !started else { return }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        started = true
    }

    /// Queue one PCM16 mono chunk.
    func enqueue(_ pcm16: Data) {
        let frames = pcm16.count / 2
        guard frames > 0, started, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        let dst = buf.floatChannelData![0]
        pcm16.withUnsafeBytes { raw in
            for i in 0..<frames { dst[i] = Float(raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)) / 32768 }
        }
        lock.lock()
        scheduledFrames += Int64(frames)
        outstanding += 1
        let gen = generation
        lock.unlock()
        node.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.completed(gen)
        }
        // The engine can be stopped underneath us between `start()` and here — a configuration
        // change or a device swap resets it on another thread — and AVAudioPlayerNode.play() raises
        // an uncatchable NSException when its engine is not running. Restart it, then re-check;
        // the buffer stays scheduled and the next chunk retries.
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch {
                Log.warn("Voice playback: output restart failed (\(error.localizedDescription))")
                return
            }
        }
        guard engine.isRunning else { return }
        if !node.isPlaying { node.play() }
    }

    private func completed(_ gen: Int) {
        lock.lock()
        guard gen == generation else { lock.unlock(); return }
        outstanding = max(0, outstanding - 1)
        let drained = outstanding == 0
        lock.unlock()
        if drained { onDrained?() }
    }

    var isPlaying: Bool { lock.lock(); defer { lock.unlock() }; return outstanding > 0 }

    /// Milliseconds rendered since the last `flush()`, clamped to what has been scheduled.
    var playedMs: Int {
        lock.lock()
        let total = Int(scheduledFrames * 1000 / Int64(Self.sampleRate))
        let done = outstanding == 0
        lock.unlock()
        if done { return total }
        guard let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt), pt.sampleRate > 0 else { return 0 }
        return max(0, min(total, Int(Double(pt.sampleTime) * 1000 / pt.sampleRate)))
    }

    /// Drop everything queued (user interrupted, or a new response starts). Resets the played-ms clock.
    func flush() {
        lock.lock()
        generation += 1
        scheduledFrames = 0
        outstanding = 0
        lock.unlock()
        node.stop()
        node.reset()
    }

    func shutdown() {
        flush()
        onDrained = nil
        if engine.isRunning { engine.stop() }
        if started { engine.detach(node) }
        started = false
    }
}

import Foundation
import AVFoundation

/// Microphone → 24 kHz Int16 mono PCM chunks (~40 ms each) for the Realtime API.
/// Runs its own AVAudioEngine input tap; conversion happens on the audio thread via AVAudioConverter.
final class MicCapture: @unchecked Sendable {
    static let sampleRate: Double = 24_000
    private static let chunkBytes = Int(sampleRate) * 2 * 40 / 1000     // 1920 bytes = 40 ms of PCM16 mono

    private let engine = AVAudioEngine()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private var tapInstalled = false
    private let microphoneUID: String

    /// `converter`, `pending` and the two callbacks are written by whoever calls `start`/`stop` and
    /// read on the audio thread, so every touch goes through this lock. Without it, `stop()`
    /// replacing `pending` while the tap was appending to it was a live data race on a `Data` buffer.
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var pending = Data()
    private var _onChunk: ((Data) -> Void)?
    private var _onLevel: ((Float) -> Void)?

    // Audio thread only.
    private var level: Float = 0
    private var levelTick = 0

    init(microphoneUID: String) {
        self.microphoneUID = microphoneUID
    }

    /// Called on the audio thread with one 40 ms PCM16 chunk.
    var onChunk: ((Data) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onChunk }
        set { lock.lock(); _onChunk = newValue; lock.unlock() }
    }
    /// Called on the audio thread ~10×/s with a 0…1 RMS level.
    var onLevel: ((Float) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onLevel }
        set { lock.lock(); _onLevel = newValue; lock.unlock() }
    }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        guard !tapInstalled else { return }
        let input = engine.inputNode
        do {
            if let name = try AudioInputDevice.useConfiguredMicrophone(for: input, preferredUID: microphoneUID) {
                Log.info("Voice mode: selected input \(name)")
            }
        } catch {
            Log.warn("Voice mode: input selection failed (\(error.localizedDescription))")
        }
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else {
            throw NSError(domain: "Avo.MicCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio input device"])
        }
        lock.lock()
        converter = AVAudioConverter(from: hw, to: outFormat)
        pending = Data(capacity: Self.chunkBytes * 4)
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 1024, format: hw) { [weak self] buf, _ in
            self?.handle(buf)
        }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() }
        catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            lock.lock(); converter = nil; lock.unlock()
            throw error
        }
    }

    func stop() {
        // Remove the tap first: after this returns no more callbacks are in flight, and the state
        // below can be cleared without racing one.
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()
        lock.lock()
        converter = nil
        pending = Data()
        _onChunk = nil
        _onLevel = nil
        lock.unlock()
    }

    // MARK: audio thread

    private func handle(_ buf: AVAudioPCMBuffer) {
        updateLevel(buf)
        lock.lock()
        guard let conv = converter else { lock.unlock(); return }
        let ratio = outFormat.sampleRate / buf.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { lock.unlock(); return }
        var err: NSError?
        var consumed = false
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buf
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { lock.unlock(); return }
        pending.append(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        var chunks: [Data] = []
        while pending.count >= Self.chunkBytes {
            chunks.append(Data(pending.prefix(Self.chunkBytes)))
            pending.removeFirst(Self.chunkBytes)
        }
        let sink = _onChunk
        lock.unlock()
        for c in chunks { sink?(c) }
    }

    private func updateLevel(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in stride(from: 0, to: n, by: 4) { sum += ch[i] * ch[i] }
        let rms = sqrt(sum / Float(max(n / 4, 1)))
        level = level * 0.6 + min(1, rms * 9) * 0.4
        levelTick += 1
        guard levelTick % 5 == 0 else { return }
        lock.lock(); let sink = _onLevel; lock.unlock()
        sink?(level)
    }
}

private extension Data {
    mutating func append(_ samples: UnsafeBufferPointer<Int16>) {
        guard let base = samples.baseAddress else { return }
        append(UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self), count: samples.count * 2)
    }
}

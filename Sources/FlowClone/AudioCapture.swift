import AVFoundation

/// Microphone → buffers in whatever format a speech engine wants, plus a level
/// meter for the HUD. Starts instantly so the first words aren't lost.
final class AudioCapture {
    private let engine = AVAudioEngine()

    /// Microphone loudness 0…1, delivered on the main thread (for the HUD meter).
    var onLevel: ((Float) -> Void)?
    /// Diagnostics: audio actually delivered.
    private(set) var buffers = 0
    private(set) var frames: AVAudioFramePosition = 0
    private(set) var peakLevel: Float = 0

    func start(as target: AVAudioFormat, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let node = engine.inputNode
        let source = node.outputFormat(forBus: 0)
        guard source.sampleRate > 0 else { throw CaptureError.noMicrophone }
        guard let converter = AVAudioConverter(from: source, to: target) else { throw CaptureError.badFormat }

        let onLevel = self.onLevel
        node.installTap(onBus: 0, bufferSize: 1024, format: source) { buffer, _ in
            if let level = Self.level(of: buffer) {
                self.peakLevel = max(self.peakLevel, level)
                if let onLevel { DispatchQueue.main.async { onLevel(level) } }
            }
            let ratio = target.sampleRate / source.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0 else { return }
            self.buffers += 1
            self.frames += AVAudioFramePosition(out.frameLength)
            onBuffer(out)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// RMS of the first channel mapped from -50…0 dBFS to 0…1.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-6))
        return max(0, min(1, (db + 50) / 50))
    }

    enum CaptureError: LocalizedError {
        case noMicrophone, badFormat
        var errorDescription: String? {
            self == .noMicrophone ? "No microphone input available" : "Couldn't convert microphone audio"
        }
    }
}

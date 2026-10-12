import AVFoundation
import FlowCore
import Foundation
import NaturalLanguage

enum ModelStatus: Equatable {
    case idle, downloading(Double), loading, ready, failed(String)
}

/// A speech model that transcribes a whole recording at once (on key release).
@MainActor
protocol BatchSpeechEngine: AnyObject {
    var status: ModelStatus { get }
    var onStatus: ((ModelStatus) -> Void)? { get set }
    func load() async
    func transcribe(samples: [Float], languages: [String], vocabulary: [String]) async throws -> Transcript
}

extension BatchSpeechEngine {
    var isReady: Bool { status == .ready }
}

/// Text-based language identification restricted to the user's languages, for
/// engines that don't report one (Wispr sends `detected_language` to its formatter).
enum LanguageGuess {
    static func of(_ text: String, among allowed: [String]) -> String? {
        if allowed.count == 1 { return allowed[0] }
        let recognizer = NLLanguageRecognizer()
        if !allowed.isEmpty { recognizer.languageConstraints = allowed.map { NLLanguage(rawValue: $0) } }
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }
}

/// Records 16 kHz mono float samples while the key is held; transcribes on release.
final class BatchDictationSession: DictationSession {
    let audio = AudioCapture()
    private let engine: any BatchSpeechEngine
    private let languages: [String]
    private var vocabulary: [String] = []
    private var samples: [Float] = []
    private let lock = NSLock()

    init(engine: any BatchSpeechEngine, languages: [String]) {
        self.engine = engine
        self.languages = languages
    }

    func start(vocabulary: [String]) async throws {
        self.vocabulary = vocabulary
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        try audio.start(as: format) { [weak self] buffer in
            guard let self, let data = buffer.floatChannelData?[0] else { return }
            let chunk = UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))
            self.lock.withLock { self.samples.append(contentsOf: chunk) }
        }
    }

    func finish() async throws -> Transcript {
        audio.stop()
        let samples = lock.withLock { self.samples }
        Self.saveForDebugging(samples)
        // Models invent text ("Thank you.", "Sous-titres…") on silence: skip near-silent clips.
        // (Speech from a laptop mic can peak as low as ~0.1 on this scale.)
        guard samples.count > 8_000, audio.peakLevel > 0.05 else { return Transcript(text: "", language: nil) }
        return try await engine.transcribe(samples: Self.normalized(samples), languages: languages, vocabulary: vocabulary)
    }

    func cancel() async {
        audio.stop()
    }

    /// Quiet laptop-mic recordings make models drop real speech as silence;
    /// bring the loudest sample up to ~0.9 (gain capped so noise isn't blown up).
    static func normalized(_ samples: [Float]) -> [Float] {
        let peak = samples.reduce(0) { max($0, abs($1)) }
        guard peak > 0, peak < 0.5 else { return samples }
        let gain = min(0.9 / peak, 20)
        return samples.map { $0 * gain }
    }

    /// Last recording as a WAV, to replay with `FlowClone --transcribe` when something goes wrong.
    static let debugRecordingURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "FlowClone/last-recording.wav")

    private static func saveForDebugging(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try? FileManager.default.createDirectory(at: debugRecordingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: debugRecordingURL)
        try? AVAudioFile(forWriting: debugRecordingURL, settings: format.settings).write(from: buffer)
    }
}

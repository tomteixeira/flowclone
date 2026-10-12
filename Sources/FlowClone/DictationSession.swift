import AVFoundation
import FlowCore
import Speech

struct Transcript {
    var text: String
    /// ISO 639-1 code when the engine knows it ("fr", "en"…).
    var language: String?
}

/// One push-to-talk recording: microphone in while the key is held, text out on release.
///
/// Wispr Flow streams Opus packets over a bidirectional gRPC stream
/// (`flow_api.v1.TranscriptionService/TranscribeStream`): an `init` message,
/// a `context` message, audio `payload`s, then `commit`, and reads `Result`s back.
protocol DictationSession: AnyObject {
    var audio: AudioCapture { get }
    func start(vocabulary: [String]) async throws
    /// Key released: stop the mic, flush the engine (Wispr's `commit`), return the text.
    func finish() async throws -> Transcript
    func cancel() async
}

/// Apple's on-device SpeechAnalyzer: streams while recording, single language.
/// Used until the Whisper model has finished downloading.
final class AppleDictationSession: DictationSession {
    let audio = AudioCapture()
    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<String, Error>?

    init(locale: Locale) { self.locale = locale }

    /// Download the on-device model for `locale` if missing.
    static func prepare(locale: Locale) async throws -> Locale {
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw DictationError.unsupportedLocale(locale.identifier)
        }
        let transcriber = makeTranscriber(locale: supported)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        return supported
    }

    private static func makeTranscriber(locale: Locale) -> DictationTranscriber {
        DictationTranscriber(
            locale: locale,
            contentHints: [.shortForm],
            transcriptionOptions: [.punctuation],
            reportingOptions: [],
            attributeOptions: []
        )
    }

    func start(vocabulary: [String]) async throws {
        let transcriber = Self.makeTranscriber(locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationError.noAudioFormat
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        input = continuation
        try audio.start(as: format) { continuation.yield(AnalyzerInput(buffer: $0)) }

        results = Task {
            // DictationTranscriber can deliver the last segment with isFinal == false
            // even after finalizeAndFinishThroughEndOfInput, so keep every result and
            // let a newer one replace whatever it overlaps (from its start onwards).
            var segments: [(start: CMTime, text: String)] = []
            for try await result in transcriber.results {
                let start = result.range.start
                segments.removeAll { $0.start >= start }
                segments.append((start, String(result.text.characters)))
            }
            return TextHeuristics.normalize(segments.map(\.text).joined(separator: " "))
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try? await analyzer.setContext(context)
        }
        try await analyzer.start(inputSequence: stream)
    }

    func finish() async throws -> Transcript {
        audio.stop()
        input?.finish()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        let text = try await results?.value ?? ""
        return Transcript(text: text, language: locale.language.languageCode?.identifier)
    }

    func cancel() async {
        audio.stop()
        input?.finish()
        await analyzer?.cancelAndFinishNow()
        results?.cancel()
    }
}

enum DictationError: LocalizedError {
    case unsupportedLocale(String), noAudioFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id): "On-device dictation doesn't support \(id)"
        case .noAudioFormat: "Couldn't negotiate an audio format with the speech model"
        }
    }
}

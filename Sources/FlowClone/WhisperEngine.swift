import AVFoundation
import FlowCore
import Foundation
import WhisperKit

/// Multilingual on-device ASR with Whisper large-v3 turbo (CoreML / Neural Engine).
///
/// Wispr Flow's own fallback ASR is Whisper-style too: `transcribeOpenAI()` posts
/// `{audio, language, prompt}` to `/llm/asr`, where `language` is the user's only
/// selected language, or else the previously detected one, and its main path sends
/// a `dictionary` built from AX words + OCR words + first/last name + user dictionary.
/// This engine reproduces that: language constrained to the user's languages, and a
/// Whisper prompt built from the same kind of vocabulary.
@MainActor
final class WhisperEngine: BatchSpeechEngine {

    static let modelVariant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    private(set) var status = ModelStatus.idle { didSet { onStatus?(status) } }
    var onStatus: ((ModelStatus) -> Void)?
    private var kit: WhisperKit?
    /// Like Wispr's `prevDetectedLanguage()`: a tie-breaker for short, ambiguous clips.
    private var lastLanguage: String?

    func load() async {
        guard kit == nil, status != .loading else { return }
        do {
            status = .downloading(0)
            let folder = try await WhisperKit.download(
                variant: Self.modelVariant, downloadBase: ModelsDirectory.url
            ) { progress in
                Task { @MainActor in self.status = .downloading(progress.fractionCompleted) }
            }
            // First load compiles the model for the Neural Engine (can take a minute or two).
            status = .loading
            let config = WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .error,
                                          prewarm: true, load: true, download: false)
            kit = try await WhisperKit(config)
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func transcribe(samples: [Float], languages: [String], vocabulary: [String]) async throws -> Transcript {
        guard let kit else { throw WhisperError.notReady }
        let language = try await chooseLanguage(kit: kit, samples: samples, allowed: languages)

        var prompt: [Int]?
        if let tokenizer = kit.tokenizer, !vocabulary.isEmpty {
            // Whisper conditions on "previous text"; a short comma list of terms biases
            // spelling. Long prompts make large-v3 turbo return nothing, so keep it small
            // (callers order the vocabulary by importance).
            let tokens = tokenizer.encode(text: " " + vocabulary.joined(separator: ", "))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            prompt = Array(tokens.prefix(40))
        }

        func decode(prompt: [Int]?) async throws -> String {
            let options = DecodingOptions(
                task: .transcribe, language: language, temperature: 0,
                usePrefillPrompt: true, detectLanguage: language == nil,
                skipSpecialTokens: true, withoutTimestamps: true,
                promptTokens: prompt, chunkingStrategy: .vad
            )
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            return TextHeuristics.normalize(results.map(\.text).joined(separator: " "))
        }
        var text = try await decode(prompt: prompt)
        if text.isEmpty, prompt != nil {
            log.info("whisper returned nothing with a \(prompt?.count ?? 0)-token prompt; retrying without it")
            text = try await decode(prompt: nil)
        }
        let detected = language
        if let detected { lastLanguage = detected }
        return Transcript(text: TextHeuristics.removingWhisperHallucinations(text), language: detected)
    }

    /// One allowed language → force it. Several → detect, but only among those
    /// (short clips are often mis-detected, e.g. French heard as English or Catalan).
    private func chooseLanguage(kit: WhisperKit, samples: [Float], allowed: [String]) async throws -> String? {
        if allowed.count == 1 { return allowed[0] }
        guard !allowed.isEmpty else { return nil } // no restriction: let Whisper detect anything
        let probs = try await kit.detectLangauge(audioArray: samples).langProbs
        let best = allowed.max { (probs[$0] ?? -.infinity) < (probs[$1] ?? -.infinity) }
        if let best, probs[best] != nil { return best }
        return lastLanguage.flatMap { allowed.contains($0) ? $0 : nil } ?? allowed.first
    }

    enum WhisperError: LocalizedError {
        case notReady
        var errorDescription: String? { "Whisper model isn't loaded yet" }
    }
}

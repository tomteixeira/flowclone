import FluidAudio
import FlowCore
import Foundation

/// NVIDIA Parakeet TDT 0.6B v3 via FluidAudio (CoreML / Neural Engine): top of the
/// Open ASR leaderboard for its size, much faster than Whisper, 25 European
/// languages with automatic language identification, punctuation and casing.
///
/// Unlike Whisper it can't be prompted, so vocabulary (Wispr's `dictionary`) is
/// applied afterwards with a conservative near-miss correction, and the language
/// is identified from the text. FluidAudio's CTC vocabulary boosting was tried and
/// rejected: its English-only spotter rewrote ordinary French and English words
/// into dictionary terms ("Bonjour Marc" → "Sarah").
@MainActor
final class ParakeetEngine: BatchSpeechEngine {
    private(set) var status = ModelStatus.idle { didSet { onStatus?(status) } }
    var onStatus: ((ModelStatus) -> Void)?
    private var manager: AsrManager?

    func load() async {
        guard manager == nil, status != .loading else { return }
        do {
            status = .downloading(0)
            let models = try await AsrModels.downloadAndLoad(version: .v3) { progress in
                Task { @MainActor in
                    if case .downloading = self.status { self.status = .downloading(progress.fractionCompleted) }
                }
            }
            status = .loading
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.manager = manager
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func transcribe(samples: [Float], languages: [String], vocabulary: [String]) async throws -> Transcript {
        guard let manager else { throw EngineError.notReady }
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        // The hint only filters tokens by script, so it matters for e.g. ru/uk/el, not fr/en.
        let hint = languages.count == 1 ? Language(rawValue: languages[0]) : nil
        let result = try await manager.transcribe(samples, decoderState: &state, language: hint)
        let text = VocabularyCorrection.apply(to: TextHeuristics.normalize(result.text), vocabulary: vocabulary)
        return Transcript(text: text, language: LanguageGuess.of(text, among: languages))
    }

    enum EngineError: LocalizedError {
        case notReady
        var errorDescription: String? { "Parakeet model isn't loaded yet" }
    }
}

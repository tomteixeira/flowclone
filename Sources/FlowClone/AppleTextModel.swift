import FlowCore
import Foundation
import FoundationModels

/// Apple's on-device foundation model behind FlowCore's `TextModel` seam.
/// Thin on purpose: prompts, guards and fallback live in `LanguageTasks`.
struct AppleTextModel: TextModel {
    let id = "apple"

    var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    func generate(instructions: String, prompt: String, options: TextGenerationOptions) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let sampling: GenerationOptions.SamplingMode? = switch options.sampling {
        case .greedy: .greedy
        case .temperature: nil
        }
        let temperature: Double? = if case .temperature(let t) = options.sampling { t } else { nil }
        let generation = GenerationOptions(sampling: sampling, temperature: temperature,
                                           maximumResponseTokens: options.maxTokens)
        return try await session.respond(to: prompt, options: generation).content
    }
}

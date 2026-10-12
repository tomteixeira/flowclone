import Foundation

/// How a model should decode. Formatting is greedy; Command Mode may sample.
public enum TextSampling: Sendable, Equatable {
    case greedy
    case temperature(Double)
}

public struct TextGenerationOptions: Sendable, Equatable {
    public var maxTokens: Int
    public var sampling: TextSampling

    public init(maxTokens: Int, sampling: TextSampling = .greedy) {
        self.maxTokens = maxTokens
        self.sampling = sampling
    }
}

/// The seam between FlowCore's language tasks and any language model
/// (Apple's foundation model, an MLX model...). Adapters stay thin: no prompt
/// logic and no guards, those live in `LanguageTasks`.
public protocol TextModel: Sendable {
    /// Stable identifier, e.g. "apple" or an MLX model id. Reported back in results.
    var id: String { get }
    /// False when the model can't run right now (not downloaded, disabled by the
    /// system...). The cascade skips it without calling `generate`.
    var isAvailable: Bool { get }
    /// Instructions are the system prompt; prompt is the user turn. Throwing makes
    /// the cascade fall through to the next model.
    func generate(instructions: String, prompt: String, options: TextGenerationOptions) async throws -> String
}

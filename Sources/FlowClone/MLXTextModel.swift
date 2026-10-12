import FlowCore
import Foundation
import HuggingFace
import MLX
import MLXLLM  // registers the LLM model factory (qwen3...); without it loading fails
import MLXLMCommon
import Tokenizers

/// Where FlowClone keeps downloaded models (speech and language), easy to find and delete.
enum ModelsDirectory {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "FlowClone/models", directoryHint: .isDirectory)
    }

    /// Hugging Face cache root for MLX models (python-compatible layout:
    /// `models--<org>--<name>/{blobs,refs,snapshots}`).
    static var huggingFace: URL { url.appending(path: "huggingface", directoryHint: .isDirectory) }
}

/// An MLX language model (one instance per Hugging Face repo) behind FlowCore's
/// `TextModel` seam. Thin on purpose: prompts, guards and fallback live in
/// `LanguageTasks`. Weights download on first use into `ModelsDirectory`; a
/// pinned revision makes later runs load from cache without touching the network.
final class MLXTextModel: TextModel {
    let spec: LocalModelSpec
    var id: String { spec.id }
    /// Download and residency are managed by the caller (ticket 06's model
    /// manager); until then the model is always offered and loads on first use.
    var isAvailable: Bool { true }

    private let loader: Loader

    init(_ spec: LocalModelSpec) {
        self.spec = spec
        self.loader = Loader(spec: spec)
    }

    /// Downloads (first run only) and loads the weights. `generate` does this
    /// lazily; call it to warm up or to time loading separately.
    func load(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        _ = try await loader.container(progress: progress)
    }

    func generate(instructions: String, prompt: String, options: TextGenerationOptions) async throws -> String {
        let container = try await loader.container(progress: { _ in })
        // Qwen3 thinking off: the chat template then pre-fills an empty <think></think>.
        let input = UserInput(chat: [.system(instructions), .user(prompt)],
                              additionalContext: ["enable_thinking": false])
        let temperature: Float = switch options.sampling {
        case .greedy: 0  // GenerateParameters defaults to 0.6
        case .temperature(let t): Float(t)
        }
        let parameters = GenerateParameters(maxTokens: options.maxTokens, temperature: temperature)
        let lmInput = try await container.prepare(input: input)
        var text = ""
        for await event in try await container.generate(input: lmInput, parameters: parameters) {
            if case .chunk(let chunk) = event { text += chunk }
        }
        try Task.checkCancellation()
        return text
    }

    /// Serializes loading so concurrent first calls share one download.
    private actor Loader {
        let spec: LocalModelSpec
        private var loaded: ModelContainer?
        private var loading: Task<ModelContainer, Error>?

        init(spec: LocalModelSpec) { self.spec = spec }

        func container(progress: @Sendable @escaping (Double) -> Void) async throws -> ModelContainer {
            if let loaded { return loaded }
            if loading == nil {
                let spec = spec
                loading = Task {
                    // The .app ships the kernels in Contents/Resources (codesign refuses
                    // data files in Contents/MacOS); `swift build` binaries find the copy
                    // scripts/build-mlx-metallib.sh puts next to them. Must precede any MLX call.
                    if GPU.metallib == nil, let bundled = Bundle.main.url(forResource: "mlx", withExtension: "metallib") {
                        GPU.metallib = bundled
                    }
                    // Cap MLX's buffer cache; the weights themselves stay resident.
                    Memory.cacheLimit = 64 * 1024 * 1024
                    let hub = HubClient(cache: HubCache(cacheDirectory: ModelsDirectory.huggingFace))
                    let container = try await loadModelContainer(
                        from: HubDownloader(hub: hub), using: HFTokenizerLoader(),
                        configuration: ModelConfiguration(id: spec.id, revision: spec.revision,
                                                          extraEOSTokens: ["<|im_end|>"]),
                        progressHandler: { progress($0.fractionCompleted) })
                    // MLX JIT-compiles its kernels on the first generation (~3 s on an M5);
                    // pay that here, during loading, not on the user's first dictation.
                    let warmUp = try await container.prepare(input: UserInput(
                        chat: [.system("Reply OK."), .user("Hi")], additionalContext: ["enable_thinking": false]))
                    for await _ in try await container.generate(input: warmUp, parameters: GenerateParameters(maxTokens: 4, temperature: 0)) {}
                    return container
                }
            }
            do {
                let container = try await loading!.value
                loaded = container
                return container
            } catch {
                loading = nil  // retry (and resume the download) on the next call
                throw error
            }
        }
    }
}

// MARK: - Hugging Face adapters (what mlx-swift-lm's MLXHuggingFace macros expand to)

private struct HubDownloader: MLXLMCommon.Downloader {
    let hub: HubClient

    func download(id: String, revision: String?, matching patterns: [String], useLatest: Bool,
                  progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else { throw URLError(.badURL) }
        return try await hub.downloadSnapshot(of: repo, revision: revision ?? "main", matching: patterns,
                                              progressHandler: { @MainActor progress in progressHandler(progress) })
    }
}

private struct HFTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

// MARK: - Factory

/// Model id → `TextModel`, for the CLI, the eval harness and `FLOWCLONE_LLM`.
enum TextModels {
    /// nil for `.off`.
    static func make(_ choice: LanguageModelOverride) -> (any TextModel)? {
        switch choice {
        case .local(let spec): MLXTextModel(spec)
        case .apple: AppleTextModel()
        case .off: nil
        }
    }

    /// "apple", "off", an alias ("qwen3-1.7b", "qwen3-4b") or a Hugging Face repo id.
    static func make(id: String) throws -> (any TextModel)? {
        guard let choice = try LanguageModelOverride.parse(id) else { throw LanguageModelOverride.InvalidValue(value: id) }
        return make(choice)
    }

    /// The `FLOWCLONE_LLM` override, nil when unset.
    static func override() throws -> LanguageModelOverride? {
        try LanguageModelOverride.fromEnvironment()
    }
}

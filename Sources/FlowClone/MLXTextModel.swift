import FlowCore
import Foundation
import HuggingFace
import MLX
import MLXLLM  // registers the LLM model factory (qwen3...); without it loading fails
import MLXLMCommon
import Synchronization
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

    /// Unmanaged (CLI, eval harness): always offered, downloads and loads on
    /// first use. Managed (the app's `LocalModelManager`): offered only when
    /// loaded; use `waiting(_:)` to also accept a load about to finish.
    var isAvailable: Bool { isAvailable(wait: .upTo(0)) }

    private func isAvailable(wait: LoadWait) -> Bool {
        guard managed else { return true }
        return residency.withLock { $0.readiness(at: Date(), wait: wait) } != .unavailable
    }

    /// The same model for one task's requests, waiting up to `wait` for a load
    /// in progress. One shared model, one residency; the budget is per request.
    func waiting(_ wait: LoadWait) -> any TextModel { Waiting(base: self, wait: wait) }

    private struct Waiting: TextModel {
        let base: MLXTextModel
        let wait: LoadWait
        var id: String { base.id }
        var isAvailable: Bool { base.isAvailable(wait: wait) }
        func generate(instructions: String, prompt: String, options: TextGenerationOptions) async throws -> String {
            try await base.generate(instructions: instructions, prompt: prompt, options: options, wait: wait)
        }
    }

    /// The managed lifecycle state; nil when unmanaged.
    var state: LocalModelResidency? { managed ? residency.withLock { $0 } : nil }

    struct Unavailable: Error {}

    private let loader: Loader
    /// Only meaningful (and only updated) when `managed`.
    private let residency: Mutex<LocalModelResidency>
    private let managed: Bool
    private let onChange: @Sendable () -> Void

    init(_ spec: LocalModelSpec) {
        self.spec = spec
        self.loader = Loader(spec: spec)
        self.residency = Mutex(LocalModelResidency())
        self.managed = false
        self.onChange = {}
    }

    /// A model whose download and residency are driven by `LocalModelManager`.
    /// `onChange` runs (on any thread) after every lifecycle change.
    init(_ spec: LocalModelSpec, policy: ResidencyPolicy, onChange: @Sendable @escaping () -> Void) {
        self.spec = spec
        self.loader = Loader(spec: spec)
        self.residency = Mutex(LocalModelResidency(policy: policy))
        self.managed = true
        self.onChange = onChange
    }

    /// Fetches the weights without loading them (no network once cached at a pinned revision).
    func download() async throws {
        let hub = HubClient(cache: HubCache(cacheDirectory: ModelsDirectory.huggingFace))
        do {
            _ = try await HubDownloader(hub: hub).download(
                id: spec.id, revision: spec.revision, matching: ["*.safetensors", "*.json", "*.jinja"],
                useLatest: false, progressHandler: { [weak self] progress in
                    self?.update { $0.downloadProgressed(progress.fractionCompleted) }
                })
            update { $0.downloadFinished() }
        } catch {
            update { $0.downloadFailed(error.localizedDescription) }
            throw error
        }
    }

    /// Downloads (first run only) and loads the weights. `generate` does this
    /// lazily when unmanaged; call it to warm up or to time loading separately.
    func load(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        update { $0.loadStarted(at: Date()) }
        do {
            _ = try await loader.container(progress: progress)
            update { $0.loadFinished(at: Date()) }
        } catch {
            update { $0.loadFailed() }
            throw error
        }
    }

    /// Releases the weights if the model sat idle past the policy's timeout.
    @discardableResult
    func unloadIfIdle(now: Date = Date()) async -> Bool {
        guard managed, residency.withLock({ $0.shouldUnload(at: now) }) else { return false }
        await loader.unload()
        update { $0.unloaded() }
        return true
    }

    private func update(_ change: (inout LocalModelResidency) -> Void) {
        guard managed else { return }
        residency.withLock { change(&$0) }
        onChange()
    }

    func generate(instructions: String, prompt: String, options: TextGenerationOptions) async throws -> String {
        try await generate(instructions: instructions, prompt: prompt, options: options, wait: .upTo(0))
    }

    private func generate(instructions: String, prompt: String, options: TextGenerationOptions,
                          wait: LoadWait) async throws -> String {
        if managed {
            // Decide and mark the use atomically so an idle unload can't slip in between.
            let readiness = residency.withLock { state -> LocalModelReadiness in
                let readiness = state.readiness(at: Date(), wait: wait)
                if readiness != .unavailable { state.useBegan() }
                return readiness
            }
            if case .wait(let budget) = readiness {
                // The load runs in its own task; poll rather than await it so
                // the cascade gives up on time. An infinite budget waits until the load ends.
                let clock = ContinuousClock()
                let deadline = budget.isFinite ? clock.now.advanced(by: .seconds(budget)) : nil
                func stillLoading() -> Bool {
                    if case .loading = residency.withLock({ $0.phase }) { return true }
                    return false
                }
                while stillLoading(), deadline.map({ clock.now < $0 }) ?? true, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if residency.withLock({ $0.phase }) != .loaded {
                    update { $0.useEnded(at: Date()) }
                    throw Unavailable()
                }
            } else if readiness == .unavailable {
                throw Unavailable()
            }
        }
        defer { update { $0.useEnded(at: Date()) } }
        return try await run(instructions: instructions, prompt: prompt, options: options)
    }

    private func run(instructions: String, prompt: String, options: TextGenerationOptions) async throws -> String {
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

        /// Drops the weights; generations already running keep their own reference.
        func unload() {
            loaded = nil
            loading = nil
            Memory.clearCache()
        }

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
}

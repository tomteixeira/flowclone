/// Which local models the app manages, which one each session mode loads, and
/// how long each may keep a transcript waiting. Formatting uses Qwen 1.7B,
/// Command Mode Qwen 4B; `FLOWCLONE_LLM` forces one model (or none) for both.
public struct LocalModelPlan: Sendable, Equatable {
    /// The local model formatting sessions use; nil when forced to Apple or off.
    public let formatting: LocalModelSpec?
    /// The local model Command Mode sessions use; nil when forced to Apple or off.
    public let command: LocalModelSpec?

    private let override: LanguageModelOverride?

    public init(override: LanguageModelOverride?) {
        self.override = override
        switch override {
        case nil:
            formatting = LocalModels.formatting
            command = LocalModels.commandMode
        case .local(let spec)?:
            formatting = spec
            command = spec
        case .apple?, .off?:
            formatting = nil
            command = nil
        }
    }

    /// Download order: the formatting model first, the Command Mode model once it's in place.
    public var downloads: [LocalModelSpec] {
        var seen = Set<LocalModelSpec>()
        return [formatting, command].compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    /// The local model a session of this mode loads. A formatting session never
    /// loads the Command Mode model, and the reverse.
    public func model(for mode: SessionMode) -> LocalModelSpec? {
        mode == .command ? command : formatting
    }

    /// Residency rules for a managed model: the Command Mode model gets the
    /// longer wait budget; a model shared with formatting keeps formatting's.
    public func policy(for spec: LocalModelSpec) -> ResidencyPolicy {
        spec == command && spec != formatting ? .commandMode : .standard
    }

    // MARK: Cascades

    /// The sources a task tries, in order: the task's own order, unless an
    /// override forces a single model (or none).
    private func order(unlessOverridden taskOrder: [ModelSource]) -> [ModelSource] {
        switch override {
        case nil: taskOrder
        case .local?: [.local]
        case .apple?: [.apple]
        case .off?: []
        }
    }

    private func formattingOrder(_ engine: FormattingEngine) -> [ModelSource] {
        order(unlessOverridden: engine.order)
    }

    /// Command Mode ignores the Formatting setting: Qwen 4B, then Apple.
    private var commandOrder: [ModelSource] { order(unlessOverridden: [.local, .apple]) }

    private static func candidates(_ order: [ModelSource], local: (any TextModel)?, apple: (any TextModel)?) -> [any TextModel] {
        order.compactMap { $0 == .local ? local : apple }
    }

    /// Formatting cascade for the user's Formatting setting. Pass nil for a model
    /// that isn't installed. An override forces its single model.
    public func formattingCandidates(engine: FormattingEngine, local: (any TextModel)?, apple: (any TextModel)?) -> [any TextModel] {
        Self.candidates(formattingOrder(engine), local: local, apple: apple)
    }

    /// Whether key-down starts loading the formatting model: only when the
    /// cascade would reach it (see `FormattingEngine.preloadsLocal`).
    public func preloadsFormattingModel(engine: FormattingEngine, appleAvailable: Bool) -> Bool {
        FormattingEngine.preloadsLocal(order: formattingOrder(engine), appleAvailable: appleAvailable)
    }

    /// Command Mode cascade: the local model, then Apple's. Pass nil for a model
    /// that isn't installed. An override forces its single model.
    public func commandCandidates(local: (any TextModel)?, apple: (any TextModel)?) -> [any TextModel] {
        Self.candidates(commandOrder, local: local, apple: apple)
    }

    /// Whether the Command Mode local model is the last model that could run
    /// Command Mode, so a load in progress is worth waiting out: Apple's model
    /// can't take over, or an override forces the local model alone.
    public func commandModelIsLastResort(appleAvailable: Bool) -> Bool {
        guard command != nil, let index = commandOrder.firstIndex(of: .local) else { return false }
        return commandOrder[(index + 1)...].allSatisfy { $0 == .apple && !appleAvailable }
    }
}

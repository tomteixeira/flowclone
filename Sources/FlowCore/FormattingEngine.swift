import Foundation

/// Where a candidate model comes from: a local MLX model (Qwen) or Apple's
/// on-device foundation model.
public enum ModelSource: String, Sendable, CaseIterable {
    case local, apple
}

/// The user's formatting-engine setting, resolved into the ordered list of
/// candidate models `LanguageTasks.format` cascades over.
public enum FormattingEngine: String, Sendable, CaseIterable {
    /// The best model available, falling back to the other one.
    case auto
    /// Apple's foundation model only.
    case apple
    /// No cleanup: the raw transcript is pasted.
    case off

    /// The order `auto` tries models in. Apple stays first until the evaluation
    /// shows the local model matching or beating it within the latency budget;
    /// then flip this to `[.local, .apple]`.
    public static let autoOrder: [ModelSource] = [.apple, .local]

    public var order: [ModelSource] {
        switch self {
        case .auto: Self.autoOrder
        case .apple: [.apple]
        case .off: []
        }
    }

    /// Candidates in cascade order. Pass nil for a model that isn't installed.
    public func candidates(local: (any TextModel)?, apple: (any TextModel)?) -> [any TextModel] {
        order.compactMap { source in
            switch source {
            case .local: local
            case .apple: apple
            }
        }
    }
}

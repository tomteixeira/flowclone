import Foundation

/// Where a candidate model comes from: a local MLX model (Qwen) or Apple's
/// on-device foundation model.
public enum ModelSource: String, Sendable, CaseIterable {
    case local, apple
}

/// The user's formatting-engine setting: the order `LanguageTasks.format`
/// cascades over models in (`LocalModelPlan.formattingCandidates` resolves it).
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

    /// The saved setting, or, before one was saved, the migrated "AI cleanup"
    /// toggle: `cleanup=false` becomes `.off`, anything else `.auto`.
    public static func fromSettings(stored: String?, legacyCleanup: Bool?) -> FormattingEngine {
        if let stored, let engine = FormattingEngine(rawValue: stored) { return engine }
        return legacyCleanup == false ? .off : .auto
    }

    public var order: [ModelSource] {
        switch self {
        case .auto: Self.autoOrder
        case .apple: [.apple]
        case .off: []
        }
    }

    /// Whether to start loading the local model at key-down: only when the
    /// cascade would actually reach it, i.e. every model ahead of it is
    /// unavailable. Keeps ~1 GB out of memory while Apple's model handles it.
    public func preloadsLocal(appleAvailable: Bool) -> Bool {
        Self.preloadsLocal(order: order, appleAvailable: appleAvailable)
    }

    public static func preloadsLocal(order: [ModelSource], appleAvailable: Bool) -> Bool {
        guard let index = order.firstIndex(of: .local) else { return false }
        return order[..<index].allSatisfy { $0 == .apple && !appleAvailable }
    }

}

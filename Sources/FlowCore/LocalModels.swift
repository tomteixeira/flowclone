import Foundation

/// A local (MLX) language model: a Hugging Face repo and the revision to fetch.
public struct LocalModelSpec: Sendable, Equatable, Hashable {
    /// Hugging Face repo id, e.g. "mlx-community/Qwen3-1.7B-4bit". Also the `TextModel.id`.
    public var id: String
    /// Commit sha (no network once cached) or a branch such as "main".
    public var revision: String

    public init(id: String, revision: String) {
        self.id = id
        self.revision = revision
    }
}

/// The 4-bit MLX conversions FlowClone uses, pinned to the commits checked on
/// huggingface.co (2026-10-12).
public enum LocalModels {
    /// Formatting. Thinking is turned off through the chat template (`enable_thinking: false`).
    public static let qwen3_1_7B = LocalModelSpec(
        id: "mlx-community/Qwen3-1.7B-4bit", revision: "3b1b1768f8f8cf8351c712464f906e86c2b8269e")
    /// Command Mode: the non-thinking Instruct-2507 variant.
    public static let qwen3_4B_Instruct2507 = LocalModelSpec(
        id: "mlx-community/Qwen3-4B-Instruct-2507-4bit", revision: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b")
    /// Command Mode fallback if Instruct-2507 disappears (thinking model, needs `enable_thinking: false`).
    public static let qwen3_4B = LocalModelSpec(
        id: "mlx-community/Qwen3-4B-4bit", revision: "4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25")

    public static let formatting = qwen3_1_7B
    public static let commandMode = qwen3_4B_Instruct2507

    static let pinned = [qwen3_1_7B, qwen3_4B_Instruct2507, qwen3_4B]
    static let aliases = ["qwen3-1.7b": formatting, "qwen3-4b": commandMode]

    /// A short alias ("qwen3-1.7b", "qwen3-4b"), a repo id ("org/name", pinned when
    /// known, else "main"), or "org/name@revision". Nil when it's none of these.
    public static func spec(for name: String) -> LocalModelSpec? {
        if let alias = aliases[name.lowercased()] { return alias }
        let parts = name.split(separator: "@", maxSplits: 1).map(String.init)
        let id = parts[0]
        let components = id.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components.allSatisfy({ !$0.isEmpty }) else { return nil }
        if parts.count == 2 { return parts[1].isEmpty ? nil : LocalModelSpec(id: id, revision: parts[1]) }
        return pinned.first { $0.id == id } ?? LocalModelSpec(id: id, revision: "main")
    }
}

/// `FLOWCLONE_LLM`: the developer override that forces a language model in the
/// app and the CLI, mirroring `FLOWCLONE_ENGINE` for speech.
public enum LanguageModelOverride: Sendable, Equatable {
    case local(LocalModelSpec)
    case apple
    case off

    public static let environmentKey = "FLOWCLONE_LLM"

    public struct InvalidValue: Error, CustomStringConvertible {
        public let value: String
        public init(value: String) { self.value = value }
        public var description: String {
            "\(LanguageModelOverride.environmentKey)=\(value): expected apple, off, qwen3-1.7b, qwen3-4b or a Hugging Face repo id (org/name[@revision])"
        }
    }

    /// Nil when unset or blank.
    public static func parse(_ value: String?) throws -> LanguageModelOverride? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        switch value.lowercased() {
        case "apple": return .apple
        case "off", "none": return .off
        default:
            guard let spec = LocalModels.spec(for: value) else { throw InvalidValue(value: value) }
            return .local(spec)
        }
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> LanguageModelOverride? {
        try parse(environment[environmentKey])
    }
}

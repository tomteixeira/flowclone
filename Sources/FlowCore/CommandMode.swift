import Foundation
import NaturalLanguage

// MARK: - Command Mode

/// A spoken instruction to apply to the selection, or to write at the cursor
/// when nothing is selected (Shift + push-to-talk).
public struct CommandRequest: Sendable, Equatable {
    /// The spoken instruction, as transcribed.
    public var instruction: String
    /// Selected text; empty when nothing is selected.
    public var selection: String
    /// Text before the selection (or cursor); only its tail is sent to the model.
    public var beforeSelection: String
    /// Text after the selection (or cursor); only its head is sent to the model.
    public var afterSelection: String
    public var category: AppCategory
    /// ISO code of the instruction from the speech engine, nil when unknown.
    public var language: String?

    public init(instruction: String, selection: String, beforeSelection: String, afterSelection: String,
                category: AppCategory, language: String?) {
        self.instruction = instruction
        self.selection = selection
        self.beforeSelection = beforeSelection
        self.afterSelection = afterSelection
        self.category = category
        self.language = language
    }
}

/// Where the Command Mode result goes.
public enum CommandAction: Sendable, Equatable {
    /// Paste over the still-active selection.
    case replaceSelection
    /// Paste at the cursor; the text already carries any separating space.
    case insertAtCursor
}

public struct CommandResult: Sendable, Equatable {
    /// What to paste.
    public var text: String
    public var action: CommandAction
    /// Model whose output was used.
    public var modelID: String

    public init(text: String, action: CommandAction, modelID: String) {
        self.text = text
        self.action = action
        self.modelID = modelID
    }
}

/// Why Command Mode has nothing to paste. The instruction itself is never pasted.
public enum CommandFailure: Error, Sendable, Equatable {
    /// The instruction was empty.
    case emptyInstruction
    /// No candidate model can run right now (not downloaded, Apple Intelligence off...).
    case noModelAvailable
    /// Every model that ran failed or gave an output the guards rejected.
    case outputRejected
}

extension CommandFailure {
    /// What the HUD says. `localModel`: where the Command Mode local model is,
    /// nil when none is used. With no model to run, a model still on its way
    /// explains why nothing happened.
    public func message(localModel: LocalModelPhase?) -> String {
        switch (self, localModel) {
        case (.emptyInstruction, _): "Didn't catch that"
        case (.outputRejected, _): "Command Mode couldn't produce usable text"
        case (.noModelAvailable, .notDownloaded?), (.noModelAvailable, .downloading?),
             (.noModelAvailable, .downloadFailed?): "Model downloading…"
        case (.noModelAvailable, .loading?): "Model loading…"
        case (.noModelAvailable, _): "No model available for Command Mode"
        }
    }
}

extension LanguageTasks {
    /// Characters of context sent on each side of the selection.
    static let commandContextLength = 300

    /// Applies a spoken instruction to the selection, or writes new text at the
    /// cursor when nothing is selected.
    ///
    /// Wispr Flow does this server-side (`POST /llm/command_mode` with
    /// `full_text`, `selected_text`, `instruction`). Here the cascade tries each
    /// model in order; an output that is empty, or runaway compared to the
    /// selection or instruction, falls through to the next model.
    public static func command(_ request: CommandRequest, models: [any TextModel]) async -> Result<CommandResult, CommandFailure> {
        let instruction = request.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return .failure(.emptyInstruction) }
        guard models.contains(where: \.isAvailable) else { return .failure(.noModelAvailable) }

        let hasSelection = !request.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let maxLength = commandMaxLength(request, hasSelection: hasSelection)
        let result = await cascade(
            models,
            instructions: commandInstructions(request, hasSelection: hasSelection),
            prompt: commandPrompt(request, hasSelection: hasSelection),
            options: TextGenerationOptions(maxTokens: maxLength / 2, sampling: .greedy)
        ) { response -> String? in
            let cleaned = TextHeuristics.stripCommandWrapping(response)
            return !cleaned.isEmpty && cleaned.count <= maxLength ? cleaned : nil
        }
        guard let (text, modelID) = result else { return .failure(.outputRejected) }
        if hasSelection {
            return .success(CommandResult(text: text, action: .replaceSelection, modelID: modelID))
        }
        let insert = TextHeuristics.withLeadingSpaceIfNeeded(text, before: request.beforeSelection)
        return .success(CommandResult(text: insert, action: .insertAtCursor, modelID: modelID))
    }

    /// Longest accepted output, in characters: a rewrite stays near the selection's
    /// size; generated text stays proportionate to what was asked.
    static func commandMaxLength(_ request: CommandRequest, hasSelection: Bool) -> Int {
        hasSelection ? request.selection.count * 3 + 300 : request.instruction.count * 10 + 600
    }

    static func commandPrompt(_ request: CommandRequest, hasSelection: Bool) -> String {
        let before = String(request.beforeSelection.suffix(commandContextLength))
        let after = String(request.afterSelection.prefix(commandContextLength))
        let target = hasSelection
            ? "<selection>\(request.selection)</selection>"
            : "<cursor/>"
        return """
        <before>\(before)</before>
        \(target)
        <after>\(after)</after>
        <instruction>\(request.instruction)</instruction>
        """
    }

    static func commandInstructions(_ request: CommandRequest, hasSelection: Bool) -> String {
        let task = hasSelection
            ? "Apply the instruction to the text inside <selection> and output the rewritten text that replaces it."
            : "Write the text the instruction asks for; it is inserted at <cursor/>, between <before> and <after>."
        let languageRule: String
        if hasSelection, let code = TextHeuristics.dominantLanguage(request.selection),
           let name = Locale(identifier: "en").localizedString(forLanguageCode: code) {
            languageRule = "Write in \(name), the language of the selection, unless the instruction asks for a translation."
        } else if hasSelection {
            languageRule = "Write in the language of the selection unless the instruction asks for a translation."
        } else if let name = request.language.flatMap({ Locale(identifier: "en").localizedString(forLanguageCode: $0) }) {
            languageRule = "Write in \(name), the language of the instruction, unless it asks for another language."
        } else {
            languageRule = "Write in the language of the instruction unless it asks for another language."
        }
        let style: String = switch request.category {
        case .email: "The text is in an email."
        case .chat: "The text is in a chat message: keep it casual and concise."
        case .code: "The text is in a code editor or terminal: output code or plain text only, no explanation."
        case .document: "The text is in a document."
        case .other: ""
        }
        return """
        You are a writing tool. The user spoke an instruction, inside <instruction> tags. \
        The surrounding text, inside <before> and <after>, is context only: never repeat it.
        \(task)
        - \(languageRule)
        - Output only the resulting text: no preamble, no explanation, no quotes, no tags, no code fences.
        \(style)
        """
    }
}

extension TextHeuristics {
    /// Strip what a model wraps a Command Mode result in: a preamble
    /// ("Here is the rewritten text:"), surrounding quotes, or a code fence
    /// around the whole output.
    public static func stripCommandWrapping(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count >= 6, t.hasPrefix("```"), t.hasSuffix("```") {
            var lines = t.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 2 {
                lines.removeFirst() // ``` or ```lang
                lines.removeLast()
                t = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let colon = t.firstIndex(of: ":"), t[..<colon].count <= 60 {
            let lead = t[..<colon].lowercased()
            if !lead.contains("\n"), ["here is", "here's", "voici", "voilà"].contains(where: lead.hasPrefix) {
                t = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return stripModelWrapping(t)
    }

    /// ISO code of the dominant language of `text`, nil when unsure.
    public static func dominantLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
    }
}

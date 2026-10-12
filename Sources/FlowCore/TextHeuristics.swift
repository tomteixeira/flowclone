import Foundation

/// Coarse category of the app being dictated into. Wispr Flow does the same:
/// its formatter picks a different model for email (`app_type`), and its main
/// bundle ships hard-coded bundle-ID lists (Mail, Outlook, Slack, VS Code...).
public enum AppCategory: String, Sendable {
    case email, chat, code, document, other

    public static func from(bundleID: String?) -> AppCategory {
        guard let id = bundleID?.lowercased() else { return .other }
        let table: [(AppCategory, [String])] = [
            (.email, ["com.apple.mail", "com.microsoft.outlook", "com.readdle.sparkdesktop",
                      "com.mimestream.mimestream", "com.superhuman"]),
            (.chat, ["com.slack", "com.tinyspeck", "com.hnc.discord", "com.discordapp", "net.whatsapp",
                     "com.apple.mobilesms", "ru.keepcoder.telegram", "com.tdesktop.telegram",
                     "com.microsoft.teams"]),
            (.code, ["com.microsoft.vscode", "com.apple.dt.xcode", "com.todesktop.230313mzl4w4u92",
                     "com.jetbrains", "dev.zed", "com.apple.terminal", "com.googlecode.iterm2",
                     "com.mitchellh.ghostty", "dev.warp"]),
            (.document, ["com.apple.notes", "com.apple.pages", "com.microsoft.word",
                         "com.apple.textedit", "md.obsidian", "notion.id"]),
        ]
        for (category, prefixes) in table where prefixes.contains(where: { id.hasPrefix($0) }) {
            return category
        }
        return .other
    }
}

public enum TextHeuristics {
    /// Collapse whitespace runs produced by joining transcriber segments.
    public static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Words worth biasing the recognizer towards, pulled from the text around
    /// the cursor. Mirrors Wispr's `DynamicVocabulary` (screen_content_ax,
    /// variable_names): proper nouns, camelCase / snake_case identifiers.
    public static func vocabulary(from surrounding: String, limit: Int = 100) -> [String] {
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).inverted
        var seen = Set<String>()
        var result: [String] = []
        for raw in surrounding.components(separatedBy: separators) {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
            guard token.count >= 3, token.count <= 40, !seen.contains(token) else { continue }
            let hasUpper = token.dropFirst().contains(where: \.isUppercase) || token.first?.isUppercase == true
            let isIdentifier = token.contains("_") || (token.contains(where: \.isLowercase) && token.dropFirst().contains(where: \.isUppercase))
            guard hasUpper || isIdentifier, token.contains(where: \.isLetter) else { continue }
            seen.insert(token)
            result.append(token)
            if result.count == limit { break }
        }
        return result
    }

    /// Wispr reports a `format_skip_reason`; very short utterances aren't worth
    /// an LLM round-trip and are where models are most likely to misbehave.
    public static func shouldSkipFormatting(_ raw: String) -> Bool {
        raw.split(whereSeparator: \.isWhitespace).count <= 3
    }

    /// Reject LLM output that looks like it answered or expanded the dictation
    /// instead of cleaning it up. Falls back to the raw transcript.
    public static func acceptFormatted(_ formatted: String, raw: String) -> Bool {
        let f = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty else { return false }
        let rawWords = raw.split(whereSeparator: \.isWhitespace).count
        let fWords = f.split(whereSeparator: \.isWhitespace).count
        // Cleanup removes fillers / self-corrections, so it may shrink a lot,
        // but it should never grow much.
        guard fWords <= Int(Double(rawWords) * 1.3) + 3, fWords * 4 >= rawWords else { return false }
        // A dictated question must stay a question; if it became a statement the
        // model answered it ("what is the capital of France" -> "...is Paris.").
        if looksLikeQuestion(raw), !f.contains("?") { return false }
        // Cleanup draws on the speaker's words; many new words means the model wrote its own.
        let rawSet = Set(words(raw))
        let novel = words(f).filter { !rawSet.contains($0) }.count
        return novel <= max(2, fWords / 5)
    }

    public static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    public static func looksLikeQuestion(_ raw: String) -> Bool {
        let fillers: Set<String> = ["um", "uh", "so", "and", "hey", "okay", "ok", "well",
                                    "euh", "bon", "alors", "donc", "et", "mais", "bah", "ben"]
        let interrogatives: Set<String> = ["what", "why", "how", "when", "where", "who", "which", "whose",
                                           "can", "could", "would", "should", "is", "are", "do", "does", "did", "will",
                                           // French ("est-ce que…" tokenizes to "est")
                                           "pourquoi", "comment", "quand", "où", "qui", "quoi", "quel", "quelle",
                                           "quels", "quelles", "combien", "est", "peux", "pouvez", "peut",
                                           "pourrais", "pourriez", "sais", "savez", "as", "avez"]
        guard let first = words(raw).first(where: { !fillers.contains($0) }) else { return false }
        return interrogatives.contains(first)
    }

    /// Phrases Whisper is known to produce from silence or noise (learned from
    /// subtitled training data). Only removed when they are the whole output.
    public static func removingWhisperHallucinations(_ text: String) -> String {
        let phantoms = [
            "thank you.", "thanks for watching!", "thank you for watching.", "you", "bye.",
            "merci.", "merci d'avoir regardé.", "merci d'avoir regardé cette vidéo.",
            "sous-titres réalisés par la communauté d'amara.org",
            "sous-titrage st' 501", "sous-titrage société radio-canada",
        ]
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return phantoms.contains(t.lowercased()) ? "" : t
    }

    /// Strip wrapping the model sometimes adds ("Here is the cleaned text: ...", quotes).
    public static func stripModelWrapping(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Here is the cleaned text:", "Here's the cleaned text:", "Cleaned text:", "Output:"]
        where t.lowercased().hasPrefix(prefix.lowercased()) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if t.count >= 2, t.first == "\"", t.last == "\"" { t = String(t.dropFirst().dropLast()) }
        // The whole output inside one tag, e.g. "<after_cursor>...</after_cursor>".
        let tagged = try! Regex(#"<([A-Za-z_]+)>(.*)</\1>"#, as: (Substring, Substring, Substring).self)
        if let match = t.wholeMatch(of: tagged.dotMatchesNewlines()) {
            let (_, tag, inner) = match.output
            if !inner.contains("<\(tag)>"), !inner.contains("</\(tag)>") {
                t = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return t
    }

    /// Insert a separating space when pasting right after a word, the way a
    /// human would continue typing (Wispr's "paste with delimiters" case).
    public static func withLeadingSpaceIfNeeded(_ text: String, before: String) -> String {
        guard let last = before.last, let first = text.first else { return text }
        if last.isWhitespace || first.isWhitespace || first.isPunctuation { return text }
        return " " + text
    }
}

import Foundation

// MARK: - Dictation journal

/// One formatting run, as logged by the opt-in dictation journal.
public struct FormattingJournalEntry: Codable, Sendable, Equatable {
    /// How much of the text before the cursor is kept.
    public static let beforeCursorLimit = 300

    public var date: Date
    public var raw: String
    /// What was pasted.
    public var formatted: String
    public var language: String?
    public var category: AppCategory
    /// Model whose output was used; nil when the raw transcript was pasted.
    public var model: String?
    /// Wall time of the language step.
    public var latencyMs: Double
    /// The last `beforeCursorLimit` characters before the cursor.
    public var beforeCursor: String
    /// Hand-added checks, used when the record is replayed as an eval case.
    public var expect: EvalExpectations?

    public init(date: Date, raw: String, formatted: String, language: String?, category: AppCategory,
                model: String?, latencyMs: Double, beforeCursor: String, expect: EvalExpectations? = nil) {
        self.date = date
        self.raw = raw
        self.formatted = formatted
        self.language = language
        self.category = category
        self.model = model
        self.latencyMs = latencyMs
        self.beforeCursor = String(beforeCursor.suffix(Self.beforeCursorLimit))
        self.expect = expect
    }
}

/// One Command Mode run, as logged by the opt-in dictation journal.
public struct CommandJournalEntry: Codable, Sendable, Equatable {
    /// How much context is kept on each side of the selection, as for formatting.
    public static let contextLimit = FormattingJournalEntry.beforeCursorLimit

    public var date: Date
    public var instruction: String
    /// Selected text; empty when nothing was selected.
    public var selection: String
    /// Context around the selection (or cursor): the last and first
    /// `contextLimit` characters.
    public var beforeSelection: String
    public var afterSelection: String
    public var category: AppCategory
    public var language: String?
    /// What was pasted; nil when Command Mode failed.
    public var result: String?
    /// Model whose output was used; nil when Command Mode failed.
    public var model: String?
    public var latencyMs: Double
    public var expect: EvalExpectations?

    public init(date: Date, instruction: String, selection: String, beforeSelection: String, afterSelection: String,
                category: AppCategory, language: String?, result: String?, model: String?, latencyMs: Double,
                expect: EvalExpectations? = nil) {
        self.date = date
        self.instruction = instruction
        self.selection = selection
        self.beforeSelection = String(beforeSelection.suffix(Self.contextLimit))
        self.afterSelection = String(afterSelection.prefix(Self.contextLimit))
        self.category = category
        self.language = language
        self.result = result
        self.model = model
        self.latencyMs = latencyMs
        self.expect = expect
    }

    public init(_ request: CommandRequest, date: Date, result: String?, model: String?, latencyMs: Double) {
        self.init(date: date, instruction: request.instruction, selection: request.selection,
                  beforeSelection: request.beforeSelection, afterSelection: request.afterSelection,
                  category: request.category, language: request.language, result: result, model: model,
                  latencyMs: latencyMs)
    }
}

/// One line of the dictation journal (JSONL). The `kind` key tells the
/// variants apart; the entry's fields sit next to it, flat.
public enum JournalRecord: Codable, Sendable, Equatable {
    case formatting(FormattingJournalEntry)
    case command(CommandJournalEntry)

    private enum Kind: String, Codable { case formatting, command }
    private enum KindKey: String, CodingKey { case kind }

    public init(from decoder: any Decoder) throws {
        switch try decoder.container(keyedBy: KindKey.self).decode(Kind.self, forKey: .kind) {
        case .formatting: self = .formatting(try FormattingJournalEntry(from: decoder))
        case .command: self = .command(try CommandJournalEntry(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: KindKey.self)
        switch self {
        case .formatting(let entry):
            try c.encode(Kind.formatting, forKey: .kind)
            try entry.encode(to: encoder)
        case .command(let entry):
            try c.encode(Kind.command, forKey: .kind)
            try entry.encode(to: encoder)
        }
    }

    public var date: Date {
        switch self {
        case .formatting(let e): e.date
        case .command(let e): e.date
        }
    }

    /// The record as one JSON object without line breaks.
    public func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// One record per non-empty line.
    public static func decodeJSONL(_ text: String) throws -> [JournalRecord] {
        try JSONL.lines(text).map(decode)
    }

    static func decode(_ line: Substring) throws -> JournalRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(JournalRecord.self, from: Data(line.utf8))
    }

    // MARK: Replaying in the evaluation

    /// The record as an evaluation case, replaying the same input. The id comes
    /// from the record's timestamp, so it survives filtering the journal.
    public var evalCase: EvalCase {
        switch self {
        case .formatting(let e):
            EvalCase(id: Self.caseID(e.date), task: .formatting, raw: e.raw, language: e.language,
                     category: e.category, beforeCursor: e.beforeCursor, tags: ["journal"], expect: e.expect)
        case .command(let e):
            EvalCase(id: Self.caseID(e.date), task: .command, raw: e.instruction, language: e.language,
                     category: e.category, beforeCursor: e.beforeSelection, selection: e.selection,
                     afterCursor: e.afterSelection, tags: ["journal"], expect: e.expect)
        }
    }

    /// The journal (or a filtered subset of its lines) as a corpus.
    public static func evalCases(fromJSONL text: String) throws -> [EvalCase] {
        try decodeJSONL(text).map(\.evalCase)
    }

    static func caseID(_ date: Date) -> String {
        "journal-\(Int64((date.timeIntervalSince1970 * 1000).rounded()))"
    }
}

extension EvalCase {
    /// A corpus file: hand-written cases and journal records, one per line, in
    /// any mix. A line with a `kind` key is a journal record.
    public static func decodeCorpus(_ text: String) throws -> [EvalCase] {
        try JSONL.lines(text).map { line in
            if line.contains(#""kind""#), let record = try? JournalRecord.decode(line) { return record.evalCase }
            return try EvalCase.decode(line)
        }
    }
}

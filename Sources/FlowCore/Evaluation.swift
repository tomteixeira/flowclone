import Foundation
import NaturalLanguage

extension AppCategory: Codable {}

/// Which language task a corpus case exercises; journal records (ticket 10)
/// convert into these cases.
public enum EvalTask: String, Codable, Sendable {
    /// `raw` is a dictation, run through `LanguageTasks.format`.
    case formatting
    /// `raw` is a spoken instruction applied to `selection` (or written at the
    /// cursor when it is empty), run through `LanguageTasks.command`.
    case command
}

/// Optional automatic checks for one case.
public struct EvalExpectations: Codable, Sendable, Equatable {
    /// Substrings that must appear, case-sensitive (proper nouns keep their spelling).
    public var contains: [String]?
    /// Words or phrases that must not appear, case-insensitive, matched on word boundaries
    /// ("um" doesn't match "summary").
    public var notContains: [String]?
    /// The trimmed output must end with this string, e.g. "?" or ".".
    public var endsWith: String?
    /// Command Mode: ISO code of the language the output must be in, e.g. the
    /// target of a translation. Defaults to the selection's language, else the
    /// case's `language`.
    public var language: String?
    /// Command Mode: the output must be at most this many characters (summaries).
    public var maxLength: Int?

    public init(contains: [String]? = nil, notContains: [String]? = nil, endsWith: String? = nil,
                language: String? = nil, maxLength: Int? = nil) {
        self.contains = contains
        self.notContains = notContains
        self.endsWith = endsWith
        self.language = language
        self.maxLength = maxLength
    }
}

/// One line of an evaluation corpus (JSONL). Fields other than `id` and `raw`
/// are optional so hand-written cases stay short.
///
/// Command Mode cases set `"task":"command"`; their spoken instruction goes in
/// `raw` (or `instruction`, read as an alias), the selected text in `selection`
/// (empty: generate at the cursor) and the text around it in `beforeCursor` /
/// `afterCursor`.
public struct EvalCase: Codable, Sendable, Equatable {
    public var id: String
    public var task: EvalTask
    /// The dictation, or the spoken instruction for a Command Mode case.
    public var raw: String
    /// ISO code of what was spoken, as the speech engine would report it.
    public var language: String?
    public var category: AppCategory
    /// Text before the cursor, or before the selection.
    public var beforeCursor: String
    /// Command Mode: the selected text; empty when nothing is selected.
    public var selection: String
    /// Command Mode: text after the selection (or cursor).
    public var afterCursor: String
    public var tags: [String]?
    public var expect: EvalExpectations?

    public init(id: String, task: EvalTask = .formatting, raw: String, language: String?, category: AppCategory = .other,
                beforeCursor: String = "", selection: String = "", afterCursor: String = "",
                tags: [String]? = nil, expect: EvalExpectations? = nil) {
        self.id = id
        self.task = task
        self.raw = raw
        self.language = language
        self.category = category
        self.beforeCursor = beforeCursor
        self.selection = selection
        self.afterCursor = afterCursor
        self.tags = tags
        self.expect = expect
    }

    enum CodingKeys: String, CodingKey {
        case id, task, raw, instruction, language, category, beforeCursor, selection, afterCursor, tags, expect
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        task = try c.decodeIfPresent(EvalTask.self, forKey: .task) ?? .formatting
        if let instruction = try c.decodeIfPresent(String.self, forKey: .instruction), !c.contains(.raw) {
            raw = instruction
        } else {
            raw = try c.decode(String.self, forKey: .raw)
        }
        language = try c.decodeIfPresent(String.self, forKey: .language)
        category = try c.decodeIfPresent(AppCategory.self, forKey: .category) ?? .other
        beforeCursor = try c.decodeIfPresent(String.self, forKey: .beforeCursor) ?? ""
        selection = try c.decodeIfPresent(String.self, forKey: .selection) ?? ""
        afterCursor = try c.decodeIfPresent(String.self, forKey: .afterCursor) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        expect = try c.decodeIfPresent(EvalExpectations.self, forKey: .expect)
    }

    /// Command Mode fields are written only when set, so formatting records keep their shape.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(task, forKey: .task)
        try c.encode(raw, forKey: .raw)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encode(category, forKey: .category)
        try c.encode(beforeCursor, forKey: .beforeCursor)
        if !selection.isEmpty { try c.encode(selection, forKey: .selection) }
        if !afterCursor.isEmpty { try c.encode(afterCursor, forKey: .afterCursor) }
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encodeIfPresent(expect, forKey: .expect)
    }

    public var formattingRequest: FormattingRequest {
        FormattingRequest(raw: raw, language: language, category: category, beforeCursor: beforeCursor)
    }

    public var commandRequest: CommandRequest {
        CommandRequest(instruction: raw, selection: selection, beforeSelection: beforeCursor,
                       afterSelection: afterCursor, category: category, language: language)
    }

    /// One case per non-empty line.
    public static func decodeJSONL(_ text: String) throws -> [EvalCase] {
        let decoder = JSONDecoder()
        return try text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try decoder.decode(EvalCase.self, from: Data($0.utf8)) }
    }
}

// MARK: - Running a case

/// What happened when a case went through the model.
public enum EvalOutcome: String, Codable, Sendable {
    /// The model's output passed the guards and is what gets pasted.
    case accepted
    /// The guards rejected the output; the raw transcript is pasted.
    case rejected
    /// The model threw.
    case error
    /// The model reported itself unavailable and wasn't called.
    case unavailable
    /// The skip heuristic bypassed the model (very short input).
    case skipped
}

/// One line of the output JSONL: everything needed to judge a case afterwards.
public struct EvalRecord: Codable, Sendable, Equatable {
    public var id: String
    public var input: EvalCase
    public var model: String
    /// What would be pasted.
    public var output: String
    /// The model's verbatim response, kept even when the guards rejected it.
    public var modelOutput: String?
    public var outcome: EvalOutcome
    /// Wall time of the language step, nil when no model was called.
    public var latencyMs: Double?
    /// Names of the failed rule checks; empty when everything passed.
    public var failures: [String]

    public init(id: String, input: EvalCase, model: String, output: String, modelOutput: String?,
                outcome: EvalOutcome, latencyMs: Double?, failures: [String]) {
        self.id = id
        self.input = input
        self.model = model
        self.output = output
        self.modelOutput = modelOutput
        self.outcome = outcome
        self.latencyMs = latencyMs
        self.failures = failures
    }
}

/// The headline numbers of a run.
public struct EvalSummary: Sendable, Equatable {
    public var cases: Int
    public var outcomes: [EvalOutcome: Int]
    /// Nearest-rank percentiles over the cases where a model was called.
    public var p50LatencyMs: Double?
    public var p95LatencyMs: Double?
    /// Time to get the model ready, measured by the caller (e.g. a warm-up call).
    public var loadTimeMs: Double?
    /// Peak resident memory of the process, measured by the caller.
    public var peakMemoryBytes: UInt64?
    /// Accepted / (accepted + rejected): how often the guards let the model's output through.
    public var guardPassRate: Double?
    public var ruleFailureCount: Int
    public var casesWithFailures: Int
    /// Failures counted by rule name (the part before ":").
    public var failuresByRule: [String: Int]

    public init(records: [EvalRecord], loadTimeMs: Double?, peakMemoryBytes: UInt64?) {
        cases = records.count
        outcomes = Dictionary(records.map { ($0.outcome, 1) }, uniquingKeysWith: +)
        let latencies = records.compactMap(\.latencyMs).sorted()
        p50LatencyMs = Self.percentile(latencies, 0.50)
        p95LatencyMs = Self.percentile(latencies, 0.95)
        self.loadTimeMs = loadTimeMs
        self.peakMemoryBytes = peakMemoryBytes
        let accepted = outcomes[.accepted, default: 0]
        let judged = accepted + outcomes[.rejected, default: 0]
        guardPassRate = judged == 0 ? nil : Double(accepted) / Double(judged)
        let all = records.flatMap(\.failures)
        ruleFailureCount = all.count
        casesWithFailures = records.filter { !$0.failures.isEmpty }.count
        failuresByRule = Dictionary(all.map { (String($0.prefix { $0 != ":" }), 1) }, uniquingKeysWith: +)
    }

    /// Human-readable block printed at the end of a run.
    public var report: String {
        func ms(_ v: Double?) -> String { v.map { String(format: "%.0f ms", $0) } ?? "n/a" }
        let memory = peakMemoryBytes.map { String(format: "%.0f MB", Double($0) / 1_048_576) } ?? "n/a"
        let passRate = guardPassRate.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"
        let outcomeList = outcomes.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }
        let ruleList = failuresByRule.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { "  \($0.key): \($0.value)" }
        return ([
            "cases: \(cases) (\(outcomeList.joined(separator: ", ")))",
            "latency p50: \(ms(p50LatencyMs)), p95: \(ms(p95LatencyMs))",
            "load time: \(ms(loadTimeMs)), peak memory: \(memory)",
            "guard pass rate: \(passRate)",
            "rule-check failures: \(ruleFailureCount) in \(casesWithFailures) cases",
        ] + ruleList).joined(separator: "\n")
    }

    /// Nearest-rank: the smallest value with at least `q` of the values at or below it.
    static func percentile(_ sorted: [Double], _ q: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((q * Double(sorted.count)).rounded(.up))
        return sorted[max(rank, 1) - 1]
    }
}

public enum Evaluation {
    /// Runs one case through a single model (no cascade: the point is to measure that model).
    public static func run(_ evalCase: EvalCase, model: any TextModel) async -> EvalRecord {
        switch evalCase.task {
        case .formatting: await runFormatting(evalCase, model: model)
        case .command: await runCommand(evalCase, model: model)
        }
    }

    /// Command Mode: the output is what would be pasted, empty when Command Mode
    /// gives up (it never pastes the instruction).
    static func runCommand(_ evalCase: EvalCase, model: any TextModel) async -> EvalRecord {
        let recorder = RecordingTextModel(model)
        let clock = ContinuousClock()
        let start = clock.now
        let result = await LanguageTasks.command(evalCase.commandRequest, models: [recorder])
        let elapsed = clock.now - start

        let call = recorder.call
        let outcome: EvalOutcome
        switch (result, call) {
        case (.success, _): outcome = .accepted
        case (.failure(.emptyInstruction), _): outcome = .skipped
        case (.failure(.noModelAvailable), _): outcome = .unavailable
        case (.failure(.outputRejected), .success?): outcome = .rejected
        case (.failure(.outputRejected), _): outcome = .error
        }
        let modelOutput: String? = if case .success(let text)? = call { text } else { nil }
        let output = (try? result.get())?.text ?? ""
        let latency: Double? = call == nil ? nil
            : Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        var record = EvalRecord(id: evalCase.id, input: evalCase, model: model.id, output: output,
                                modelOutput: modelOutput, outcome: outcome, latencyMs: latency, failures: [])
        record.failures = EvalRules.failures(for: record)
        return record
    }

    static func runFormatting(_ evalCase: EvalCase, model: any TextModel) async -> EvalRecord {
        let recorder = RecordingTextModel(model)
        let clock = ContinuousClock()
        let start = clock.now
        let result = await LanguageTasks.format(evalCase.formattingRequest, models: [recorder])
        let elapsed = clock.now - start

        let call = recorder.call
        let outcome: EvalOutcome
        switch call {
        case nil: outcome = model.isAvailable ? .skipped : .unavailable
        case .failure?: outcome = .error
        case .success?: outcome = result.modelID == nil ? .rejected : .accepted
        }
        let modelOutput: String? = if case .success(let text)? = call { text } else { nil }
        let latency: Double? = call == nil ? nil
            : Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        var record = EvalRecord(id: evalCase.id, input: evalCase, model: model.id, output: result.text,
                                modelOutput: modelOutput, outcome: outcome, latencyMs: latency, failures: [])
        record.failures = EvalRules.failures(for: record)
        return record
    }
}

/// Passes calls through to the wrapped model and remembers the last response.
final class RecordingTextModel: TextModel, @unchecked Sendable {
    enum Call: Equatable { case success(String), failure }

    private let base: any TextModel
    private let lock = NSLock()
    private var _call: Call?
    var call: Call? { lock.withLock { _call } }

    init(_ base: any TextModel) { self.base = base }

    var id: String { base.id }
    var isAvailable: Bool { base.isAvailable }

    func generate(instructions: String, prompt: String, options: TextGenerationOptions) async throws -> String {
        do {
            let text = try await base.generate(instructions: instructions, prompt: prompt, options: options)
            lock.withLock { _call = .success(text) }
            return text
        } catch {
            lock.withLock { _call = .failure }
            throw error
        }
    }
}

// MARK: - Rule checks

/// Automatic checks on a record. They judge the model's own output (wrapping
/// stripped) when there is one, even if the guards rejected it, so a failure
/// says what the model did; otherwise they judge what would be pasted.
public enum EvalRules {
    public static func failures(for record: EvalRecord) -> [String] {
        var failures: [String] = []
        switch record.outcome {
        case .rejected: failures.append("guards_rejected")
        // No output to judge: content checks would only repeat this failure.
        case .error: return ["model_error"]
        case .unavailable: return ["model_unavailable"]
        case .accepted, .skipped: break
        }
        if record.input.task == .command { return failures + commandFailures(for: record) }
        let raw = record.input.raw
        let text = record.modelOutput.map(TextHeuristics.stripModelWrapping) ?? record.output

        // Only a model can answer; a skipped input is pasted as spoken.
        if record.modelOutput != nil, TextHeuristics.looksLikeQuestion(raw), !text.contains("?") {
            failures.append("answered_question")
        }
        if let expected = record.input.language, let detected = dominantLanguage(text), detected != expected {
            failures.append("language_changed")
        }
        return failures + expectationFailures(record.input.expect, text: text)
    }

    static func expectationFailures(_ expect: EvalExpectations?, text: String) -> [String] {
        guard let expect else { return [] }
        var failures: [String] = []
        for s in expect.contains ?? [] where !text.contains(s) {
            failures.append("expect_contains:\(s)")
        }
        for s in expect.notContains ?? [] where containsPhrase(text, s) {
            failures.append("expect_not_contains:\(s)")
        }
        if let end = expect.endsWith, !text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(end) {
            failures.append("expect_ends_with:\(end)")
        }
        if let max = expect.maxLength, text.count > max {
            failures.append("expect_max_length:\(max)")
        }
        return failures
    }

    /// Command Mode checks, on the model's output with its wrapping stripped:
    /// - empty_output: nothing left to paste.
    /// - wrapped: the model added a preamble, quotes, tags or a code fence.
    /// - language_changed: not in `expect.language`, else the selection's
    ///   language, else the case's `language` (generation with no selection).
    /// - unchanged: the selection came back as is.
    /// - too_long / too_short: longer than Command Mode accepts, or under a
    ///   tenth of the selection.
    static func commandFailures(for record: EvalRecord) -> [String] {
        let input = record.input
        let modelOutput = record.modelOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = modelOutput.map(TextHeuristics.stripCommandWrapping)
            ?? record.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ["empty_output"] }

        var failures: [String] = []
        if let modelOutput, text != modelOutput { failures.append("wrapped") }

        let selection = input.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedLanguage = input.expect?.language
            ?? (selection.isEmpty ? input.language : dominantLanguage(selection))
        if let expectedLanguage, let detected = dominantLanguage(text), detected != expectedLanguage {
            failures.append("language_changed")
        }
        if !selection.isEmpty, text == selection { failures.append("unchanged") }
        if text.count > LanguageTasks.commandMaxLength(input.commandRequest, hasSelection: !selection.isEmpty) {
            failures.append("too_long")
        } else if !selection.isEmpty, text.count < selection.count / 10 {
            failures.append("too_short")
        }
        return failures + expectationFailures(input.expect, text: text)
    }

    /// Case-insensitive, on word boundaries.
    static func containsPhrase(_ text: String, _ phrase: String) -> Bool {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}\\p{N}])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// French or English, for texts long enough to tell (4+ words); nil otherwise.
    static func dominantLanguage(_ text: String) -> String? {
        guard TextHeuristics.words(text).count >= 4 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.french, .english]
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }
}

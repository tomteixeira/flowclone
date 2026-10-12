import Foundation
import NaturalLanguage

extension AppCategory: Codable {}

/// Which language task a corpus case exercises. Command Mode cases come next
/// (ticket 09); journal records (ticket 10) convert into these cases.
public enum EvalTask: String, Codable, Sendable {
    case formatting
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

    public init(contains: [String]? = nil, notContains: [String]? = nil, endsWith: String? = nil) {
        self.contains = contains
        self.notContains = notContains
        self.endsWith = endsWith
    }
}

/// One line of an evaluation corpus (JSONL). Fields other than `id` and `raw`
/// are optional so hand-written cases stay short.
public struct EvalCase: Codable, Sendable, Equatable {
    public var id: String
    public var task: EvalTask
    public var raw: String
    public var language: String?
    public var category: AppCategory
    public var beforeCursor: String
    public var tags: [String]?
    public var expect: EvalExpectations?

    public init(id: String, task: EvalTask = .formatting, raw: String, language: String?, category: AppCategory = .other,
                beforeCursor: String = "", tags: [String]? = nil, expect: EvalExpectations? = nil) {
        self.id = id
        self.task = task
        self.raw = raw
        self.language = language
        self.category = category
        self.beforeCursor = beforeCursor
        self.tags = tags
        self.expect = expect
    }

    enum CodingKeys: String, CodingKey { case id, task, raw, language, category, beforeCursor, tags, expect }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        task = try c.decodeIfPresent(EvalTask.self, forKey: .task) ?? .formatting
        raw = try c.decode(String.self, forKey: .raw)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        category = try c.decodeIfPresent(AppCategory.self, forKey: .category) ?? .other
        beforeCursor = try c.decodeIfPresent(String.self, forKey: .beforeCursor) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        expect = try c.decodeIfPresent(EvalExpectations.self, forKey: .expect)
    }

    public var formattingRequest: FormattingRequest {
        FormattingRequest(raw: raw, language: language, category: category, beforeCursor: beforeCursor)
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
        let raw = record.input.raw
        let text = record.modelOutput.map(TextHeuristics.stripModelWrapping) ?? record.output

        // Only a model can answer; a skipped input is pasted as spoken.
        if record.modelOutput != nil, TextHeuristics.looksLikeQuestion(raw), !text.contains("?") {
            failures.append("answered_question")
        }
        if let expected = record.input.language, let detected = dominantLanguage(text), detected != expected {
            failures.append("language_changed")
        }
        if let expect = record.input.expect {
            for s in expect.contains ?? [] where !text.contains(s) {
                failures.append("expect_contains:\(s)")
            }
            for s in expect.notContains ?? [] where containsPhrase(text, s) {
                failures.append("expect_not_contains:\(s)")
            }
            if let end = expect.endsWith, !text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(end) {
                failures.append("expect_ends_with:\(end)")
            }
        }
        return failures
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

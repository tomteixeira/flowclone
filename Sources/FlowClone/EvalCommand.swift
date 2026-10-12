import FlowCore
import Foundation

/// Developer evaluation of the language tasks (formatting, and Command Mode for
/// cases with `"task":"command"`), no UI or permissions needed:
///   FlowClone --eval <corpus.jsonl> [--engine <model>] [--out <file.jsonl>]
/// `<model>` is anything `FLOWCLONE_LLM` accepts (apple, qwen3-1.7b, qwen3-4b,
/// org/name[@revision]); `--engine` wins over `FLOWCLONE_LLM`, default apple.
/// Runs every case through `Evaluation` with one model, writes one JSON record
/// per case and prints a summary. See the README, "Evaluating the formatting step".
enum EvalCommand {
    /// The language model the harness runs, by command-line name: "apple", an
    /// alias ("qwen3-1.7b", "qwen3-4b") or a Hugging Face repo id (MLX).
    /// Nil for "off" or a name the factory doesn't know.
    static func textModel(named name: String) -> (any TextModel)? {
        try? TextModels.make(id: name)
    }

    /// `--engine`, else `FLOWCLONE_LLM`, else Apple's model.
    static func engineName(arguments: [String], environment: [String: String]) -> String {
        if let i = arguments.firstIndex(of: "--engine"), i + 1 < arguments.count { return arguments[i + 1] }
        if let value = environment[LanguageModelOverride.environmentKey]?.trimmingCharacters(in: .whitespaces),
           !value.isEmpty { return value }
        return "apple"
    }

    static func run(arguments: [String]) async -> Int32 {
        guard let i = arguments.firstIndex(of: "--eval"), i + 1 < arguments.count else {
            return fail("usage: FlowClone --eval <corpus.jsonl> [--engine <apple|qwen3-1.7b|qwen3-4b|org/name[@rev]>] [--out <file.jsonl>]")
        }
        func option(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let corpusPath = arguments[i + 1]
        let engine = engineName(arguments: arguments, environment: ProcessInfo.processInfo.environment)
        let outPath = option("--out") ?? "eval-\(engine.replacingOccurrences(of: "/", with: "_")).jsonl"

        guard let model = textModel(named: engine) else { return fail("unknown engine: \(engine)") }
        let cases: [EvalCase]
        do {
            cases = try EvalCase.decodeCorpus(String(contentsOfFile: corpusPath, encoding: .utf8))
        } catch {
            return fail("can't read corpus \(corpusPath): \(error)")
        }
        guard model.isAvailable else {
            return fail("engine \(engine) is unavailable (Apple Intelligence off, or model not downloaded)")
        }

        // Load time, measured before the timed cases so they don't pay for it.
        let clock = ContinuousClock()
        let warmStart = clock.now
        if let mlx = model as? MLXTextModel {
            // Download (first run only), load and kernel warm-up.
            do {
                try await mlx.load { printToStandardError("llm: downloading \(Int($0 * 100))%") }
            } catch {
                return fail("can't load \(mlx.id): \(error)")
            }
        } else {
            // A first tiny call, which brings the model into memory.
            _ = try? await model.generate(instructions: "Reply with OK.", prompt: "OK",
                                          options: TextGenerationOptions(maxTokens: 4))
        }
        let loadTime = (clock.now - warmStart).milliseconds

        var records: [EvalRecord] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lines = ""
        for (n, evalCase) in cases.enumerated() {
            let record = await Evaluation.run(evalCase, model: model)
            records.append(record)
            if let data = try? encoder.encode(record) { lines += String(decoding: data, as: UTF8.self) + "\n" }
            let mark = record.failures.isEmpty ? "ok" : record.failures.joined(separator: " ")
            printToStandardError("[\(n + 1)/\(cases.count)] \(record.id) \(record.outcome.rawValue) "
                   + "\(record.latencyMs.map { String(format: "%.0fms", $0) } ?? "-") \(mark)")
        }
        do {
            try lines.write(toFile: outPath, atomically: true, encoding: .utf8)
        } catch {
            return fail("can't write \(outPath): \(error)")
        }

        let summary = EvalSummary(records: records, loadTimeMs: loadTime, peakMemoryBytes: peakResidentBytes())
        print("engine: \(model.id)\noutput: \(outPath)\n\(summary.report)")
        return 0
    }

    /// Peak resident set size of this process. Apple's model runs in a system
    /// daemon, so this only covers in-process models (MLX).
    static func peakResidentBytes() -> UInt64? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return UInt64(usage.ru_maxrss) // bytes on macOS
    }

    static func printToStandardError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static func fail(_ message: String) -> Int32 {
        printToStandardError(message)
        return 1
    }
}

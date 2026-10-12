import FlowCore
import Foundation

/// Developer evaluation of the formatting step, no UI or permissions needed:
///   FlowClone --eval <corpus.jsonl> [--engine apple] [--out <file.jsonl>]
/// Runs every case through `Evaluation` with one model, writes one JSON record
/// per case and prints a summary. See the README, "Evaluating the formatting step".
enum EvalCommand {
    /// The language models the harness can run, by command-line name.
    /// Any `TextModel` can be added here (MLX models come with ticket 04).
    static func textModel(named name: String) -> (any TextModel)? {
        switch name {
        case "apple": AppleTextModel()
        default: nil
        }
    }

    static func run(arguments: [String]) async -> Int32 {
        guard let i = arguments.firstIndex(of: "--eval"), i + 1 < arguments.count else {
            return fail("usage: FlowClone --eval <corpus.jsonl> [--engine apple] [--out <file.jsonl>]")
        }
        func option(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let corpusPath = arguments[i + 1]
        let engine = option("--engine") ?? "apple"
        let outPath = option("--out") ?? "eval-\(engine.replacingOccurrences(of: "/", with: "_")).jsonl"

        guard let model = textModel(named: engine) else { return fail("unknown engine: \(engine)") }
        let cases: [EvalCase]
        do {
            cases = try EvalCase.decodeJSONL(String(contentsOfFile: corpusPath, encoding: .utf8))
        } catch {
            return fail("can't read corpus \(corpusPath): \(error)")
        }
        guard model.isAvailable else {
            return fail("engine \(engine) is unavailable (Apple Intelligence off, or model not downloaded)")
        }

        // Load time: a first tiny call, which brings the model into memory.
        let clock = ContinuousClock()
        let warmStart = clock.now
        _ = try? await model.generate(instructions: "Reply with OK.", prompt: "OK",
                                      options: TextGenerationOptions(maxTokens: 4))
        let loadTime = milliseconds(clock.now - warmStart)

        var records: [EvalRecord] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lines = ""
        for (n, evalCase) in cases.enumerated() {
            let record = await Evaluation.run(evalCase, model: model)
            records.append(record)
            if let data = try? encoder.encode(record) { lines += String(decoding: data, as: UTF8.self) + "\n" }
            let mark = record.failures.isEmpty ? "ok" : record.failures.joined(separator: " ")
            stderr("[\(n + 1)/\(cases.count)] \(record.id) \(record.outcome.rawValue) "
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

    static func milliseconds(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    static func stderr(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static func fail(_ message: String) -> Int32 {
        stderr(message)
        return 1
    }
}

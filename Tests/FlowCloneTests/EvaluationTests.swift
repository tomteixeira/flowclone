import FlowCore
import XCTest

final class EvaluationTests: XCTestCase {
    func testDecodesFormattingCaseFromJSONLine() throws {
        let line = #"{"id":"en-q1","raw":"um can you send me the report","language":"en","category":"chat","beforeCursor":"Hi","expect":{"contains":["report"],"notContains":["um"],"endsWith":"?"}}"#
        let cases = try EvalCase.decodeJSONL(line + "\n\n")
        XCTAssertEqual(cases.count, 1)
        let c = cases[0]
        XCTAssertEqual(c.id, "en-q1")
        XCTAssertEqual(c.task, .formatting)
        XCTAssertEqual(c.formattingRequest, FormattingRequest(raw: "um can you send me the report", language: "en", category: .chat, beforeCursor: "Hi"))
        XCTAssertEqual(c.expect?.contains, ["report"])
        XCTAssertEqual(c.expect?.notContains, ["um"])
        XCTAssertEqual(c.expect?.endsWith, "?")
    }

    let question = EvalCase(id: "q", raw: "um can you send me the report by friday", language: "en", category: .chat)

    func testAcceptedOutputIsPastedAndRecorded() async {
        let model = FakeTextModel("apple", reply: .text("Can you send me the report by Friday?"))
        let record = await Evaluation.run(question, model: model)
        XCTAssertEqual(record.id, "q")
        XCTAssertEqual(record.model, "apple")
        XCTAssertEqual(record.outcome, .accepted)
        XCTAssertEqual(record.output, "Can you send me the report by Friday?")
        XCTAssertEqual(record.modelOutput, "Can you send me the report by Friday?")
        XCTAssertEqual(record.input, question)
        XCTAssertNotNil(record.latencyMs)
    }

    func testRejectedOutputFallsBackToRawButKeepsModelOutput() async {
        let model = FakeTextModel("apple", reply: .text("Sure, I will send you the report by Friday afternoon."))
        let record = await Evaluation.run(question, model: model)
        XCTAssertEqual(record.outcome, .rejected)
        XCTAssertEqual(record.output, question.raw)
        XCTAssertEqual(record.modelOutput, "Sure, I will send you the report by Friday afternoon.")
    }

    func testThrowingModelIsRecordedAsError() async {
        let record = await Evaluation.run(question, model: FakeTextModel("apple", reply: .error))
        XCTAssertEqual(record.outcome, .error)
        XCTAssertEqual(record.output, question.raw)
        XCTAssertNil(record.modelOutput)
    }

    func testUnavailableModelIsRecordedWithoutLatency() async {
        let model = FakeTextModel("apple", available: false, reply: .text("x"))
        let record = await Evaluation.run(question, model: model)
        XCTAssertEqual(record.outcome, .unavailable)
        XCTAssertNil(record.latencyMs)
    }

    func testShortInputIsSkippedWithoutCallingTheModel() async {
        let model = FakeTextModel("apple", reply: .text("Yes."))
        let record = await Evaluation.run(EvalCase(id: "s", raw: "yes", language: "en"), model: model)
        XCTAssertEqual(record.outcome, .skipped)
        XCTAssertEqual(record.output, "yes")
        XCTAssertNil(record.latencyMs)
        XCTAssertEqual(model.calls, 0)
    }

    // MARK: Rule checks

    func failures(_ evalCase: EvalCase, reply: FakeTextModel.Reply) async -> [String] {
        await Evaluation.run(evalCase, model: FakeTextModel("m", reply: reply)).failures
    }

    func testCleanAcceptedOutputHasNoFailures() async {
        let c = EvalCase(id: "q", raw: question.raw, language: "en",
                         expect: EvalExpectations(contains: ["Friday"], notContains: ["um"], endsWith: "?"))
        let result = await failures(c, reply: .text("Can you send me the report by Friday?"))
        XCTAssertEqual(result, [])
    }

    func testUnmetExpectationsAreNamed() async {
        let c = EvalCase(id: "q", raw: "um so tell Kameleoon that the deploy is done", language: "en",
                         expect: EvalExpectations(contains: ["Kameleoon"], notContains: ["um", "so"], endsWith: "."))
        let result = await failures(c, reply: .text("Um so tell Chameleon that the deploy is done"))
        XCTAssertEqual(result, ["expect_contains:Kameleoon", "expect_not_contains:um", "expect_not_contains:so", "expect_ends_with:."])
    }

    func testNotContainsMatchesWholeWordsIgnoringCase() async {
        let c = EvalCase(id: "q", raw: "please send the summary to the whole team today", language: "en",
                         expect: EvalExpectations(notContains: ["um", "you know"]))
        let clean = await failures(c, reply: .text("Please send the summary to the whole team today."))
        XCTAssertEqual(clean, [])
        let filler = await failures(c, reply: .text("You know, send the summary to the whole team today."))
        XCTAssertEqual(filler, ["expect_not_contains:you know"])
    }

    func testGuardRejectionAndAnsweredQuestionAreFailures() async {
        let c = EvalCase(id: "q", raw: "what is the capital of france", language: "en")
        let result = await failures(c, reply: .text("The capital of France is Paris."))
        XCTAssertEqual(result, ["guards_rejected", "answered_question"])
    }

    func testSkippedShortQuestionIsNotAnAnsweredQuestion() async {
        let result = await failures(EvalCase(id: "s", raw: "are you free", language: "en"), reply: .text("Yes."))
        XCTAssertEqual(result, [])
    }

    func testModelErrorAndUnavailableAreFailures() async {
        let error = await failures(question, reply: .error)
        XCTAssertEqual(error, ["model_error"])
        let offline = await Evaluation.run(question, model: FakeTextModel("m", available: false, reply: .text("x")))
        XCTAssertEqual(offline.failures, ["model_unavailable"])
    }

    func testTranslatedOutputFailsLanguageCheck() async {
        let c = EvalCase(id: "fr", raw: "euh est-ce que tu peux m'envoyer le devis avant jeudi", language: "fr")
        let kept = await failures(c, reply: .text("Est-ce que tu peux m'envoyer le devis avant jeudi ?"))
        XCTAssertEqual(kept, [])
        let translated = await failures(c, reply: .text("Can you send me the quote before Thursday?"))
        XCTAssertEqual(translated, ["guards_rejected", "language_changed"])
    }

    // MARK: Summary

    func record(_ outcome: EvalOutcome, latency: Double?, failures: [String] = []) -> EvalRecord {
        EvalRecord(id: "x", input: question, model: "m", output: "", modelOutput: nil,
                   outcome: outcome, latencyMs: latency, failures: failures)
    }

    func testSummaryReportsNearestRankLatencyPercentilesOverModelCalls() {
        let records = stride(from: 100.0, through: 10, by: -10).map { record(.accepted, latency: $0) }
            + [record(.skipped, latency: nil)]
        let summary = EvalSummary(records: records, loadTimeMs: 250, peakMemoryBytes: 1_000_000)
        XCTAssertEqual(summary.cases, 11)
        XCTAssertEqual(summary.p50LatencyMs, 50)
        XCTAssertEqual(summary.p95LatencyMs, 100)
        XCTAssertEqual(summary.loadTimeMs, 250)
        XCTAssertEqual(summary.peakMemoryBytes, 1_000_000)
    }

    func testSummaryCountsGuardPassRateAndRuleFailures() {
        let records = [
            record(.accepted, latency: 1),
            record(.accepted, latency: 1, failures: ["expect_contains:Friday", "expect_ends_with:?"]),
            record(.accepted, latency: 1, failures: ["expect_contains:Kameleoon"]),
            record(.rejected, latency: 1, failures: ["guards_rejected"]),
            record(.skipped, latency: nil),
            record(.error, latency: 1, failures: ["model_error"]),
        ]
        let summary = EvalSummary(records: records, loadTimeMs: nil, peakMemoryBytes: nil)
        XCTAssertEqual(summary.guardPassRate, 0.75) // 3 accepted of 4 outputs judged by the guards
        XCTAssertEqual(summary.ruleFailureCount, 5)
        XCTAssertEqual(summary.casesWithFailures, 4)
        XCTAssertEqual(summary.failuresByRule, ["expect_contains": 2, "expect_ends_with": 1,
                                                "guards_rejected": 1, "model_error": 1])
        XCTAssertEqual(summary.outcomes, [.accepted: 3, .rejected: 1, .skipped: 1, .error: 1])
    }

    func testSummaryWithoutModelCallsHasNoPercentiles() {
        let summary = EvalSummary(records: [record(.skipped, latency: nil)], loadTimeMs: nil, peakMemoryBytes: nil)
        XCTAssertNil(summary.p50LatencyMs)
        XCTAssertNil(summary.guardPassRate)
    }
}

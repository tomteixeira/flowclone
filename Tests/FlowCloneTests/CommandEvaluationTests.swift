import FlowCore
import XCTest

final class CommandEvaluationTests: XCTestCase {
    func testDecodesCommandCaseFromJSONLine() throws {
        let line = #"{"id":"en-tone-1","task":"command","instruction":"make this more polite","selection":"Send me the file now.","beforeCursor":"Hi Tom,\n","afterCursor":"\nThanks","language":"en","category":"email","expect":{"language":"en","contains":["file"]}}"#
        let c = try XCTUnwrap(EvalCase.decodeJSONL(line).first)
        XCTAssertEqual(c.task, .command)
        XCTAssertEqual(c.raw, "make this more polite")
        XCTAssertEqual(c.commandRequest, CommandRequest(instruction: "make this more polite", selection: "Send me the file now.",
                                                         beforeSelection: "Hi Tom,\n", afterSelection: "\nThanks",
                                                         category: .email, language: "en"))
        XCTAssertEqual(c.expect?.language, "en")
    }

    func testStarterCorpusIsAllCommandCasesInFrenchAndEnglish() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../eval/command-corpus.jsonl")
        let cases = try EvalCase.decodeJSONL(String(contentsOf: url, encoding: .utf8))
        XCTAssertGreaterThanOrEqual(cases.count, 30)
        XCTAssertTrue(cases.allSatisfy { $0.task == .command })
        XCTAssertEqual(Set(cases.compactMap(\.language)), ["en", "fr"])
        XCTAssertEqual(Set(cases.flatMap { $0.tags ?? [] }),
                       ["tone", "translate", "summarize", "grammar", "generate", "reply"])
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count)
    }

    let polite = EvalCase(id: "tone", task: .command, raw: "make this more polite", language: "en", category: .email,
                          selection: "Send me the file now.")

    func testCommandCaseRunsThroughCommandModeAndRecordsTheReplacement() async {
        let model = FakeTextModel("apple", reply: .text("Could you please send me the file?"))
        let record = await Evaluation.run(polite, model: model)
        XCTAssertEqual(record.outcome, .accepted)
        XCTAssertEqual(record.output, "Could you please send me the file?")
        XCTAssertEqual(record.modelOutput, "Could you please send me the file?")
        XCTAssertEqual(record.failures, [])
        XCTAssertNotNil(record.latencyMs)
        XCTAssertTrue(model.lastPrompt.contains("<selection>Send me the file now.</selection>"))
    }

    func testGeneratedTextWithNoSelectionIsRecordedAsInsertedAtTheCursor() async {
        let c = EvalCase(id: "gen", task: .command, raw: "write a one-line thank you note", language: "en",
                         beforeCursor: "Done.")
        let record = await Evaluation.run(c, model: FakeTextModel("m", reply: .text("Thanks a lot for your help!")))
        XCTAssertEqual(record.outcome, .accepted)
        XCTAssertEqual(record.output, " Thanks a lot for your help!")
        XCTAssertEqual(record.failures, [])
    }

    func testRejectedCommandOutputPastesNothing() async {
        let record = await Evaluation.run(polite, model: FakeTextModel("m", reply: .text("   ")))
        XCTAssertEqual(record.outcome, .rejected)
        XCTAssertEqual(record.output, "")
        XCTAssertEqual(record.failures, ["guards_rejected", "empty_output"])
    }

    func testCommandErrorAndUnavailableModel() async {
        let error = await Evaluation.run(polite, model: FakeTextModel("m", reply: .error))
        XCTAssertEqual(error.outcome, .error)
        XCTAssertEqual(error.failures, ["model_error"])
        let offline = await Evaluation.run(polite, model: FakeTextModel("m", available: false, reply: .text("x")))
        XCTAssertEqual(offline.outcome, .unavailable)
        XCTAssertNil(offline.latencyMs)
    }

    // MARK: Rule checks

    func failures(_ c: EvalCase, reply: String) async -> [String] {
        await Evaluation.run(c, model: FakeTextModel("m", reply: .text(reply))).failures
    }

    func testWrappedOutputIsAFailureEvenWhenStripped() async {
        let preamble = await failures(polite, reply: "Here is the rewritten text: Could you please send me the file?")
        XCTAssertEqual(preamble, ["wrapped"])
        let tags = await failures(polite, reply: "<selection>Could you please send me the file?</selection>")
        XCTAssertEqual(tags, ["wrapped"])
    }

    func testOutputMustKeepTheSelectionLanguageUnlessTranslationIsExpected() async {
        let fr = EvalCase(id: "fr", task: .command, raw: "make it more formal", language: "en",
                          selection: "Tu peux m'envoyer le devis avant jeudi ?")
        let kept = await failures(fr, reply: "Pourriez-vous m'envoyer le devis avant jeudi ?")
        XCTAssertEqual(kept, [])
        let translated = await failures(fr, reply: "Could you send me the quote before Thursday?")
        XCTAssertEqual(translated, ["language_changed"])

        var translate = fr
        translate.raw = "translate this to English"
        translate.expect = EvalExpectations(language: "en")
        let asked = await failures(translate, reply: "Could you send me the quote before Thursday?")
        XCTAssertEqual(asked, [])
    }

    func testUnchangedSelectionAndLengthAreChecked() async {
        let unchanged = await failures(polite, reply: "Send me the file now.")
        XCTAssertEqual(unchanged, ["unchanged"])

        let long = String(repeating: "The meeting moved to Monday. ", count: 20)
        var summarize = EvalCase(id: "sum", task: .command, raw: "summarize this in one sentence", language: "en",
                                 selection: long, expect: EvalExpectations(maxLength: 80))
        let tooLong = await failures(summarize, reply: String(repeating: "The meeting moved to Monday. ", count: 5))
        XCTAssertEqual(tooLong, ["expect_max_length:80"])
        summarize.expect = nil
        let tooShort = await failures(summarize, reply: "Moved.")
        XCTAssertEqual(tooShort, ["too_short"])
    }
}

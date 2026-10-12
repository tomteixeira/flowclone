import FlowCore
import XCTest

final class DictationJournalTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_760_000_000.25)

    lazy var formatting = JournalRecord.formatting(FormattingJournalEntry(
        date: date, raw: "euh tu peux m'envoyer le rapport", formatted: "Tu peux m'envoyer le rapport ?",
        language: "fr", category: .chat, model: "apple", latencyMs: 312.5, beforeCursor: "Salut,\n"))

    lazy var command = JournalRecord.command(CommandJournalEntry(
        date: date, instruction: "make this more formal", selection: "hey can u send it",
        beforeSelection: "Hi Tom,\n", afterSelection: "\nThanks", category: .email, language: "en",
        result: "Could you please send it?", model: "apple", latencyMs: 820))

    func testRecordsRoundTripOnePerLine() throws {
        let jsonl = try formatting.jsonLine() + "\n" + command.jsonLine() + "\n"
        XCTAssertEqual(jsonl.split(separator: "\n").count, 2)
        XCTAssertEqual(try JournalRecord.decodeJSONL(jsonl), [formatting, command])
    }

    func testKeepsOnlyThe300CharactersBeforeTheCursor() {
        let long = String(repeating: "a", count: 500) + "end"
        let entry = FormattingJournalEntry(date: date, raw: "x", formatted: "x", language: nil, category: .other,
                                           model: nil, latencyMs: 0, beforeCursor: long)
        XCTAssertEqual(entry.beforeCursor.count, 300)
        XCTAssertTrue(entry.beforeCursor.hasSuffix("aend"))
    }

    func testFormattingRecordBecomesAFormattingEvalCase() throws {
        let evalCase = try XCTUnwrap(formatting.evalCase)
        XCTAssertEqual(evalCase.id, "journal-1760000000250")
        XCTAssertEqual(evalCase.task, .formatting)
        XCTAssertEqual(evalCase.formattingRequest, FormattingRequest(
            raw: "euh tu peux m'envoyer le rapport", language: "fr", category: .chat, beforeCursor: "Salut,\n"))
        XCTAssertEqual(evalCase.tags, ["journal"])
        XCTAssertNil(evalCase.expect)
    }

    func testHandAddedExpectationsCarryIntoTheEvalCase() throws {
        let line = #"{"kind":"formatting","date":1760000000250,"raw":"um hi","formatted":"Hi.","category":"chat","latencyMs":10,"beforeCursor":"","expect":{"notContains":["um"]}}"#
        let cases = try JournalRecord.evalCases(fromJSONL: line)
        XCTAssertEqual(cases.first?.expect, EvalExpectations(notContains: ["um"]))
    }

    func testCommandRecordsAreNotEvalCasesYet() {
        XCTAssertNil(command.evalCase)
    }

    func testCorpusMixesJournalLinesAndHandWrittenCases() throws {
        let corpus = try formatting.jsonLine() + "\n" + command.jsonLine() + "\n"
            + #"{"id":"en-1","raw":"hello there","language":"en"}"# + "\n"
        let cases = try EvalCase.decodeCorpus(corpus)
        XCTAssertEqual(cases.map(\.id), ["journal-1760000000250", "en-1"])
    }
}

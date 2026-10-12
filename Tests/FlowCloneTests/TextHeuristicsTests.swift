import FlowCore
import XCTest

final class TextHeuristicsTests: XCTestCase {
    func testCategoryFromBundleID() {
        XCTAssertEqual(AppCategory.from(bundleID: "com.apple.mail"), .email)
        XCTAssertEqual(AppCategory.from(bundleID: "com.tinyspeck.slackmacgap"), .chat)
        XCTAssertEqual(AppCategory.from(bundleID: "com.microsoft.VSCode"), .code)
        XCTAssertEqual(AppCategory.from(bundleID: "com.example.unknown"), .other)
        XCTAssertEqual(AppCategory.from(bundleID: nil), .other)
    }

    func testVocabularyPicksProperNounsAndIdentifiers() {
        let vocab = TextHeuristics.vocabulary(from: "Ping Kameleoon about the getUserMedia bug in audio_worklet.ts, thanks a lot")
        XCTAssertTrue(vocab.contains("Kameleoon"))
        XCTAssertTrue(vocab.contains("getUserMedia"))
        XCTAssertTrue(vocab.contains("audio_worklet"))
        XCTAssertFalse(vocab.contains("thanks"))
        XCTAssertFalse(vocab.contains("the"))
    }

    func testVocabularyDedupesAndLimits() {
        let vocab = TextHeuristics.vocabulary(from: "Alpha Alpha Bravo Charlie", limit: 2)
        XCTAssertEqual(vocab, ["Alpha", "Bravo"])
    }

    func testAcceptFormattedRejectsExpansionAndEmpty() {
        let raw = "um so can you uh send me the report by friday"
        XCTAssertTrue(TextHeuristics.acceptFormatted("Can you send me the report by Friday?", raw: raw))
        XCTAssertFalse(TextHeuristics.acceptFormatted("", raw: raw))
        let answer = "Sure! Here is a detailed plan for sending the report: first, gather all the data from the team, then compile it into a document and send it before Friday."
        XCTAssertFalse(TextHeuristics.acceptFormatted(answer, raw: raw))
    }

    func testAcceptFormattedRejectsAnsweredQuestion() {
        // Observed from the on-device model before prompt hardening.
        XCTAssertFalse(TextHeuristics.acceptFormatted("The capital of France is Paris.", raw: "what is the capital of France"))
        XCTAssertTrue(TextHeuristics.acceptFormatted("What is the capital of France?", raw: "what is the capital of France"))
    }

    func testAcceptFormattedAllowsSelfCorrection() {
        XCTAssertTrue(TextHeuristics.acceptFormatted("Let's meet at 3 on Monday.", raw: "let's meet at 2 no actually 3 on Monday"))
    }

    func testStripModelWrapping() {
        XCTAssertEqual(TextHeuristics.stripModelWrapping("Here is the cleaned text: \"Hello there.\""), "Hello there.")
        XCTAssertEqual(TextHeuristics.stripModelWrapping("  Hello.  "), "Hello.")
    }

    func testLeadingSpace() {
        XCTAssertEqual(TextHeuristics.withLeadingSpaceIfNeeded("world", before: "hello"), " world")
        XCTAssertEqual(TextHeuristics.withLeadingSpaceIfNeeded("world", before: "hello "), "world")
        XCTAssertEqual(TextHeuristics.withLeadingSpaceIfNeeded(", world", before: "hello"), ", world")
        XCTAssertEqual(TextHeuristics.withLeadingSpaceIfNeeded("Hello", before: ""), "Hello")
    }

    func testSkipFormattingForShortUtterances() {
        XCTAssertTrue(TextHeuristics.shouldSkipFormatting("yes please"))
        XCTAssertFalse(TextHeuristics.shouldSkipFormatting("let's meet tomorrow at noon"))
    }

    func testFrenchQuestionStaysQuestion() {
        XCTAssertFalse(TextHeuristics.acceptFormatted("La capitale de la France est Paris.", raw: "euh quelle est la capitale de la France"))
        XCTAssertTrue(TextHeuristics.acceptFormatted("Quelle est la capitale de la France ?", raw: "euh quelle est la capitale de la France"))
        XCTAssertTrue(TextHeuristics.looksLikeQuestion("est-ce que tu peux m'envoyer le rapport"))
    }

    func testWhisperHallucinationsRemovedOnlyWhenWholeOutput() {
        XCTAssertEqual(TextHeuristics.removingWhisperHallucinations("Merci d'avoir regardé."), "")
        XCTAssertEqual(TextHeuristics.removingWhisperHallucinations("Thank you."), "")
        XCTAssertEqual(TextHeuristics.removingWhisperHallucinations("Thank you for the report."), "Thank you for the report.")
    }
}

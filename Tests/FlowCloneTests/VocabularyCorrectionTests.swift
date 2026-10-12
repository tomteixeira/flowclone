import FlowCore
import XCTest

final class VocabularyCorrectionTests: XCTestCase {
    func testSnapsNearMissToTerm() {
        XCTAssertEqual(VocabularyCorrection.apply(to: "Envoie le rapport Kameleon à Sarah.", vocabulary: ["Kameleoon"]),
                       "Envoie le rapport Kameleoon à Sarah.")
    }

    func testAdoptsCasingOnExactMatch() {
        XCTAssertEqual(VocabularyCorrection.apply(to: "ping kameleoon now", vocabulary: ["Kameleoon"]), "ping Kameleoon now")
    }

    func testLeavesUnrelatedWordsAlone() {
        let text = "Le chameau mange une pomme."
        XCTAssertEqual(VocabularyCorrection.apply(to: text, vocabulary: ["Kameleoon", "Texeira"]), text)
    }

    func testIgnoresShortTerms() {
        XCTAssertEqual(VocabularyCorrection.apply(to: "the cat sat", vocabulary: ["Cut"]), "the cat sat")
    }

    func testPreservesPunctuation() {
        XCTAssertEqual(VocabularyCorrection.apply(to: "Hi Texiera, ok?", vocabulary: ["Texeira"]), "Hi Texeira, ok?")
    }
}

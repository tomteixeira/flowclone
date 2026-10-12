import FlowCore
import XCTest

final class LocalModelTests: XCTestCase {
    // MARK: Qwen3 thinking never reaches the output

    func testThinkBlockIsStripped() {
        let response = "<think>\nThe user wants a cleanup.\n</think>\n\nOn se voit à 15h ?"
        XCTAssertEqual(TextHeuristics.stripModelWrapping(response), "On se voit à 15h ?")
    }

    func testUnterminatedThinkingYieldsNothingSoTheGuardsReject() {
        let response = "<think>\nThe user wants a cleanup, so I should"
        XCTAssertEqual(TextHeuristics.stripModelWrapping(response), "")
    }

    func testFormattingNeverPastesThinking() async {
        let model = FakeTextModel("qwen", reply: .text("<think>\nhmm\n</think>\n\nLet's meet at 3 on Monday."))
        let request = FormattingRequest(raw: "let's meet at 2 no actually 3 on monday", language: "en",
                                        category: .other, beforeCursor: "")
        let result = await LanguageTasks.format(request, models: [model])
        XCTAssertEqual(result.text, "Let's meet at 3 on Monday.")
    }
}

final class LocalModelSpecTests: XCTestCase {
    func testDefaultModelsHaveShortNamesOthersTheirRepoName() {
        XCTAssertEqual(LocalModels.qwen3_1_7B.displayName, "Qwen3 1.7B")
        XCTAssertEqual(LocalModels.qwen3_4B_Instruct2507.displayName, "Qwen3 4B")
        XCTAssertEqual(LocalModelSpec(id: "org/Some-Model-4bit", revision: "main").displayName, "Some-Model-4bit")
    }
}

final class LanguageModelOverrideTests: XCTestCase {
    func testUnsetOrBlankMeansNoOverride() throws {
        XCTAssertNil(try LanguageModelOverride.parse(nil))
        XCTAssertNil(try LanguageModelOverride.parse("  "))
    }

    func testKnownRepoIdUsesItsPinnedRevision() throws {
        XCTAssertEqual(try LanguageModelOverride.parse("mlx-community/Qwen3-1.7B-4bit"),
                       .local(LocalModelSpec(id: "mlx-community/Qwen3-1.7B-4bit",
                                             revision: "3b1b1768f8f8cf8351c712464f906e86c2b8269e")))
    }

    func testShortAliasesNameTheTaskModels() throws {
        XCTAssertEqual(try LanguageModelOverride.parse("qwen3-1.7b"), .local(LocalModels.qwen3_1_7B))
        XCTAssertEqual(try LanguageModelOverride.parse("Qwen3-4B"), .local(LocalModels.qwen3_4B_Instruct2507))
        XCTAssertEqual(LocalModels.formatting, LocalModels.commandMode)
        XCTAssertEqual(LocalModels.commandMode.id, "mlx-community/Qwen3-4B-Instruct-2507-4bit")
    }

    func testAnyOtherRepoIdTracksMainUnlessARevisionIsGiven() throws {
        XCTAssertEqual(try LanguageModelOverride.parse("mlx-community/Qwen3-1.7B-4bit-DWQ-053125"),
                       .local(LocalModelSpec(id: "mlx-community/Qwen3-1.7B-4bit-DWQ-053125", revision: "main")))
        XCTAssertEqual(try LanguageModelOverride.parse("me/model@abc123"),
                       .local(LocalModelSpec(id: "me/model", revision: "abc123")))
    }

    func testAppleAndOffSelectTheOtherEngines() throws {
        XCTAssertEqual(try LanguageModelOverride.parse("apple"), .apple)
        XCTAssertEqual(try LanguageModelOverride.parse("off"), .off)
    }

    func testGarbageIsAnError() {
        XCTAssertThrowsError(try LanguageModelOverride.parse("qwen"))
        XCTAssertThrowsError(try LanguageModelOverride.parse("a/b/c"))
    }
}

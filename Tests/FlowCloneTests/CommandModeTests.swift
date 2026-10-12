import FlowCore
import XCTest

final class CommandModeTests: XCTestCase {
    let selection = "hey can u send the deck before friday thx"

    func request(_ instruction: String = "make this more formal", selection: String? = nil,
                 before: String = "", after: String = "") -> CommandRequest {
        CommandRequest(instruction: instruction, selection: selection ?? self.selection,
                       beforeSelection: before, afterSelection: after, category: .email, language: "en")
    }

    func testSelectionIsReplacedWithModelOutput() async {
        let model = FakeTextModel("apple", reply: .text("Could you please send the deck before Friday? Thank you."))
        let result = await LanguageTasks.command(request(), models: [model])
        XCTAssertEqual(result, .success(CommandResult(
            text: "Could you please send the deck before Friday? Thank you.",
            action: .replaceSelection, modelID: "apple")))
    }

    func testNoSelectionInsertsAtCursorWithLeadingSpace() async {
        let model = FakeTextModel("apple", reply: .text("Hi Sam, can we move the meeting to Thursday?"))
        let result = await LanguageTasks.command(
            request("write a short email moving the meeting to Thursday", selection: "", before: "Notes:"),
            models: [model])
        XCTAssertEqual(result, .success(CommandResult(
            text: " Hi Sam, can we move the meeting to Thursday?", action: .insertAtCursor, modelID: "apple")))
    }

    func testWhitespaceOnlySelectionCountsAsNoSelection() async {
        let model = FakeTextModel("apple", reply: .text("Thanks!"))
        let result = await LanguageTasks.command(request("say thanks", selection: "  "), models: [model])
        XCTAssertEqual(try? result.get().action, .insertAtCursor)
    }

    // MARK: Cascade

    func testUnavailableModelIsSkippedWithoutBeingCalled() async {
        let qwen = FakeTextModel("qwen", available: false, reply: .text("Never used."))
        let apple = FakeTextModel("apple", reply: .text("Could you send the deck before Friday?"))
        let result = await LanguageTasks.command(request(), models: [qwen, apple])
        XCTAssertEqual(try? result.get().modelID, "apple")
        XCTAssertEqual(qwen.calls, 0)
    }

    func testThrowingModelFallsThroughToNext() async {
        let qwen = FakeTextModel("qwen", reply: .error)
        let apple = FakeTextModel("apple", reply: .text("Could you send the deck before Friday?"))
        let result = await LanguageTasks.command(request(), models: [qwen, apple])
        XCTAssertEqual(try? result.get().text, "Could you send the deck before Friday?")
    }

    func testNoAvailableModelFailsWithoutCallingAnything() async {
        let qwen = FakeTextModel("qwen", available: false, reply: .text("Never used."))
        let r1 = await LanguageTasks.command(request(), models: [qwen])
        XCTAssertEqual(r1, .failure(.noModelAvailable))
        let r2 = await LanguageTasks.command(request(), models: [])
        XCTAssertEqual(r2, .failure(.noModelAvailable))
        XCTAssertEqual(qwen.calls, 0)
    }

    // MARK: HUD message on failure

    func testNoModelWhileTheLocalModelDownloadsSaysSo() {
        XCTAssertEqual(CommandFailure.noModelAvailable.message(localModel: .downloading(0.3)), "Model downloading…")
        XCTAssertEqual(CommandFailure.noModelAvailable.message(localModel: .notDownloaded), "Model downloading…")
        XCTAssertEqual(CommandFailure.noModelAvailable.message(localModel: .downloadFailed("offline")), "Model downloading…")
        XCTAssertEqual(CommandFailure.noModelAvailable.message(localModel: .loading(since: Date())), "Model loading…")
    }

    func testNoModelWithNothingInProgressKeepsTheGenericMessage() {
        XCTAssertEqual(CommandFailure.noModelAvailable.message(localModel: nil), "No model available for Command Mode")
        XCTAssertEqual(CommandFailure.noModelAvailable.message(localModel: .downloaded), "No model available for Command Mode")
        XCTAssertEqual(CommandFailure.outputRejected.message(localModel: .downloading(0.3)),
                       "Command Mode couldn't produce usable text")
    }

    func testEmptyInstructionFailsWithoutCallingModel() async {
        let model = FakeTextModel("apple", reply: .text("Anything."))
        let r3 = await LanguageTasks.command(request("  "), models: [model])
        XCTAssertEqual(r3, .failure(.emptyInstruction))
        XCTAssertEqual(model.calls, 0)
    }

    // MARK: Guards

    func testEmptyOutputIsRejectedAndNextModelUsed() async {
        let qwen = FakeTextModel("qwen", reply: .text("  \n"))
        let apple = FakeTextModel("apple", reply: .text("Could you send the deck before Friday?"))
        let result = await LanguageTasks.command(request(), models: [qwen, apple])
        XCTAssertEqual(try? result.get().modelID, "apple")
    }

    func testRunawayOutputIsRejected() async {
        let runaway = String(repeating: "Could you please send the deck before Friday? ", count: 100)
        let model = FakeTextModel("apple", reply: .text(runaway))
        let r4 = await LanguageTasks.command(request(), models: [model])
        XCTAssertEqual(r4, .failure(.outputRejected))
    }

    func testRunawayGenerationWithoutSelectionIsRejected() async {
        let model = FakeTextModel("apple", reply: .text(String(repeating: "Lorem ipsum dolor sit amet. ", count: 200)))
        let result = await LanguageTasks.command(request("write a reply", selection: ""), models: [model])
        XCTAssertEqual(result, .failure(.outputRejected))
    }

    /// Stops at the token limit, each token one character: the shortest output
    /// a model can give when it hits `maxTokens`.
    private final class TokenLimitedModel: TextModel, @unchecked Sendable {
        let id = "qwen"
        let isAvailable = true
        func generate(instructions: String, prompt: String, options: TextGenerationOptions) async throws -> String {
            String(repeating: "a", count: options.maxTokens)
        }
    }

    func testOutputCutOffAtTheTokenLimitIsRejected() async {
        let withSelection = await LanguageTasks.command(request(), models: [TokenLimitedModel()])
        XCTAssertEqual(withSelection, .failure(.outputRejected))
        let atCursor = await LanguageTasks.command(request("write a reply", selection: ""), models: [TokenLimitedModel()])
        XCTAssertEqual(atCursor, .failure(.outputRejected))
    }

    func testEveryModelRejectedGivesTypedFailure() async {
        let qwen = FakeTextModel("qwen", reply: .error)
        let apple = FakeTextModel("apple", reply: .text(""))
        let r5 = await LanguageTasks.command(request(), models: [qwen, apple])
        XCTAssertEqual(r5, .failure(.outputRejected))
    }

    func testModelWrappingIsStripped() async {
        let cases = [
            "Here is the rewritten text: Could you send the deck before Friday?",
            "\"Could you send the deck before Friday?\"",
            "```\nCould you send the deck before Friday?\n```",
            "Voici le texte : Could you send the deck before Friday?",
            "Sure! Here's the rewritten text: Could you send the deck before Friday?",
            "Sure! Here’s a more formal version:\n\nCould you send the deck before Friday?",
            "Bien sûr, voici le texte : Could you send the deck before Friday?",
            "Certainly, I made it more formal:\nCould you send the deck before Friday?",
        ]
        for reply in cases {
            let model = FakeTextModel("apple", reply: .text(reply))
            let result = await LanguageTasks.command(request(), models: [model])
            XCTAssertEqual(try? result.get().text, "Could you send the deck before Friday?", reply)
        }
    }

    func testAnOutputThatOnlyStartsLikeAPreambleIsKept() async {
        for reply in ["Of course we can meet: Friday works.", "Sure, Friday works: see you then."] {
            let model = FakeTextModel("apple", reply: .text(reply))
            let result = await LanguageTasks.command(request("reply yes", selection: ""), models: [model])
            XCTAssertEqual(try? result.get().text, reply, reply)
        }
    }

    func testCodeInsideFenceKeepsItsLines() async {
        let model = FakeTextModel("apple", reply: .text("```swift\nlet a = 1\nlet b = 2\n```"))
        let result = await LanguageTasks.command(request("rename x to a", selection: "let x = 1\nlet b = 2"),
                                                 models: [model])
        XCTAssertEqual(try? result.get().text, "let a = 1\nlet b = 2")
    }

    // MARK: Prompt contract

    func testPromptCarriesInstructionSelectionAndBoundedContext() async {
        let model = FakeTextModel("apple", reply: .text("Could you send the deck?"))
        let before = String(repeating: "a", count: 1000) + "BEFORE-TAIL"
        let after = "AFTER-HEAD" + String(repeating: "z", count: 1000)
        _ = await LanguageTasks.command(request(before: before, after: after), models: [model])
        let prompt = model.lastPrompt
        XCTAssertTrue(prompt.contains("make this more formal"))
        XCTAssertTrue(prompt.contains(selection))
        XCTAssertTrue(prompt.contains("BEFORE-TAIL"))
        XCTAssertTrue(prompt.contains("AFTER-HEAD"))
        XCTAssertLessThan(prompt.count, 800, "about 300 characters of context on each side")
    }

    func testOutputLanguageFollowsTheSelection() async {
        let model = FakeTextModel("apple", reply: .text("Pourriez-vous m'envoyer le devis avant jeudi ?"))
        _ = await LanguageTasks.command(
            CommandRequest(instruction: "make this more formal",
                           selection: "tu peux m'envoyer le devis avant jeudi stp, merci beaucoup",
                           beforeSelection: "", afterSelection: "", category: .email, language: "en"),
            models: [model])
        XCTAssertTrue(model.lastInstructions.contains("French"))
        XCTAssertTrue(model.lastInstructions.contains("translation"))
    }
}

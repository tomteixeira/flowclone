import FlowCore
import XCTest

/// Scripted stand-in for a language model. Records whether it was asked anything.
final class FakeTextModel: TextModel, @unchecked Sendable {
    enum Reply { case text(String), error }

    let id: String
    let isAvailable: Bool
    private let reply: Reply
    private let lock = NSLock()
    private var _calls = 0
    private var _lastInstructions = ""
    private var _lastPrompt = ""
    var calls: Int { lock.withLock { _calls } }
    var lastInstructions: String { lock.withLock { _lastInstructions } }
    var lastPrompt: String { lock.withLock { _lastPrompt } }

    init(_ id: String, available: Bool = true, reply: Reply) {
        self.id = id
        self.isAvailable = available
        self.reply = reply
    }

    func generate(instructions: String, prompt: String, options: TextGenerationOptions) async throws -> String {
        lock.withLock {
            _calls += 1
            _lastInstructions = instructions
            _lastPrompt = prompt
        }
        switch reply {
        case .text(let text): return text
        case .error: throw NSError(domain: "fake", code: 1)
        }
    }
}

final class FormattingTests: XCTestCase {
    let raw = "um so can you uh send me the report by friday"

    func request(_ raw: String) -> FormattingRequest {
        FormattingRequest(raw: raw, language: "en", category: .chat, beforeCursor: "")
    }

    func testUsesFirstModelOutput() async {
        let model = FakeTextModel("a", reply: .text("Can you send me the report by Friday?"))
        let result = await LanguageTasks.format(request(raw), models: [model])
        XCTAssertEqual(result.text, "Can you send me the report by Friday?")
        XCTAssertEqual(result.modelID, "a")
    }

    func testUnavailableModelIsSkippedWithoutBeingCalled() async {
        let offline = FakeTextModel("qwen", available: false, reply: .text("Never used."))
        let apple = FakeTextModel("apple", reply: .text("Can you send me the report by Friday?"))
        let result = await LanguageTasks.format(request(raw), models: [offline, apple])
        XCTAssertEqual(result.text, "Can you send me the report by Friday?")
        XCTAssertEqual(result.modelID, "apple")
        XCTAssertEqual(offline.calls, 0)
    }

    func testThrowingModelFallsThroughToNext() async {
        let broken = FakeTextModel("qwen", reply: .error)
        let apple = FakeTextModel("apple", reply: .text("Can you send me the report by Friday?"))
        let result = await LanguageTasks.format(request(raw), models: [broken, apple])
        XCTAssertEqual(result.modelID, "apple")
    }

    func testNoModelLeftGivesRawTranscript() async {
        let broken = FakeTextModel("qwen", reply: .error)
        let offline = FakeTextModel("apple", available: false, reply: .text("Never used."))
        let result = await LanguageTasks.format(request(raw), models: [broken, offline])
        XCTAssertEqual(result, FormattingResult(text: raw, modelID: nil))
        let none = await LanguageTasks.format(request(raw), models: [])
        XCTAssertEqual(none, FormattingResult(text: raw, modelID: nil))
    }

    // MARK: Guards

    func testAnsweredQuestionFallsThroughToNextModel() async {
        // Observed from the on-device model before prompt hardening.
        let answering = FakeTextModel("qwen", reply: .text("The capital of France is Paris."))
        let apple = FakeTextModel("apple", reply: .text("What is the capital of France?"))
        let result = await LanguageTasks.format(request("um what is the capital of France"), models: [answering, apple])
        XCTAssertEqual(result, FormattingResult(text: "What is the capital of France?", modelID: "apple"))
    }

    func testExpansionFallsBackToRaw() async {
        let chatty = FakeTextModel("apple", reply: .text("Sure! Here is a detailed plan for sending the report: first, gather all the data from the team, then compile it into a document and send it before Friday."))
        let result = await LanguageTasks.format(request(raw), models: [chatty])
        XCTAssertEqual(result, FormattingResult(text: raw, modelID: nil))
    }

    func testEmptyOutputFallsBackToRaw() async {
        let empty = FakeTextModel("apple", reply: .text("   "))
        let result = await LanguageTasks.format(request(raw), models: [empty])
        XCTAssertEqual(result, FormattingResult(text: raw, modelID: nil))
    }

    func testModelWrappingIsStripped() async {
        let wrapping = FakeTextModel("apple", reply: .text("Here is the cleaned text: \"Can you send me the report by Friday?\""))
        let result = await LanguageTasks.format(request(raw), models: [wrapping])
        XCTAssertEqual(result.text, "Can you send me the report by Friday?")
    }

    func testWrappingOnlyOutputFallsThrough() async {
        let wrapperOnly = FakeTextModel("qwen", reply: .text("Here is the cleaned text:"))
        let apple = FakeTextModel("apple", reply: .text("Can you send me the report by Friday?"))
        let result = await LanguageTasks.format(request(raw), models: [wrapperOnly, apple])
        XCTAssertEqual(result.modelID, "apple")
    }

    // MARK: Skip heuristic

    func testShortDictationSkipsModels() async {
        let model = FakeTextModel("apple", reply: .text("Yes, please."))
        let result = await LanguageTasks.format(request("yes please"), models: [model])
        XCTAssertEqual(result, FormattingResult(text: "yes please", modelID: nil))
        XCTAssertEqual(model.calls, 0)
    }

    // MARK: Prompt contract

    func testDictationIsFencedAsDataAndLanguageIsPinned() async {
        let model = FakeTextModel("apple", reply: .text("Est-ce que tu peux m'envoyer le devis avant jeudi ?"))
        let dictation = "euh est-ce que tu peux m'envoyer le devis avant jeudi"
        _ = await LanguageTasks.format(FormattingRequest(raw: dictation, language: "fr", category: .email,
                                                         beforeCursor: "Bonjour Marc,"), models: [model])
        XCTAssertTrue(model.lastPrompt.contains("<dictation>\(dictation)</dictation>"))
        XCTAssertTrue(model.lastPrompt.contains("Bonjour Marc,"))
        XCTAssertTrue(model.lastInstructions.contains("French"), "the language rule names the dictation's language")
    }

    // MARK: Vocabulary

    func testVocabularyFixesTheModelsSpelling() async {
        let model = FakeTextModel("qwen", reply: .text("Can you send the Kameleon report by Friday?"))
        let request = FormattingRequest(raw: "um can you send the kameleoon report by friday", language: "en",
                                        category: .chat, beforeCursor: "", vocabulary: ["Kameleoon"])
        let result = await LanguageTasks.format(request, models: [model])
        XCTAssertEqual(result.text, "Can you send the Kameleoon report by Friday?")
        XCTAssertEqual(result.modelID, "qwen")
    }

    func testVocabularyAlsoAppliesToTheRawFallback() async {
        let request = FormattingRequest(raw: "send the kameleon report by friday", language: "en",
                                        category: .chat, beforeCursor: "", vocabulary: ["Kameleoon"])
        let result = await LanguageTasks.format(request, models: [])
        XCTAssertEqual(result, FormattingResult(text: "send the Kameleoon report by friday", modelID: nil))
    }

    // MARK: Engine choice

    func testOffNeverCallsAModel() async {
        let local = FakeTextModel("qwen", reply: .text("Can you send me the report by Friday?"))
        let apple = FakeTextModel("apple", reply: .text("Can you send me the report by Friday?"))
        let models = LocalModelPlan(override: nil).formattingCandidates(engine: .off, local: local, apple: apple)
        let result = await LanguageTasks.format(request(raw), models: models)
        XCTAssertEqual(result, FormattingResult(text: raw, modelID: nil))
        XCTAssertEqual(local.calls + apple.calls, 0)
    }

    func testAppleUsesOnlyTheAppleModel() async {
        let local = FakeTextModel("qwen", reply: .text("Can you send me the report by Friday?"))
        let apple = FakeTextModel("apple", reply: .error)
        let models = LocalModelPlan(override: nil).formattingCandidates(engine: .apple, local: local, apple: apple)
        let result = await LanguageTasks.format(request(raw), models: models)
        XCTAssertEqual(result, FormattingResult(text: raw, modelID: nil))
        XCTAssertEqual(local.calls, 0)
    }

    func testAutoOffersEveryInstalledModel() async {
        let local = FakeTextModel("qwen", available: false, reply: .text("Never used."))
        let apple = FakeTextModel("apple", available: false, reply: .text("Never used."))
        XCTAssertEqual(LocalModelPlan(override: nil).formattingCandidates(engine: .auto, local: local, apple: apple).map(\.id).sorted(), ["apple", "qwen"])
        // While the local model isn't installed yet, auto is just Apple.
        XCTAssertEqual(LocalModelPlan(override: nil).formattingCandidates(engine: .auto, local: nil, apple: apple).map(\.id), ["apple"])
    }
}

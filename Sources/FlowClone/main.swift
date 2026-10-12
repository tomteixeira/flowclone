import FlowCore
import AppKit
import AVFoundation

// Developer check, no UI or permissions needed:
//   FlowClone --transcribe <audio file> [fr,en] [Vocab,Words]   → real ASR + cleanup pipeline
//   (FLOWCLONE_ENGINE=whisper to test Whisper instead of Parakeet)
if let i = CommandLine.arguments.firstIndex(of: "--transcribe"), i + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[i + 1]
    let languages = i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2].split(separator: ",").map(String.init) : ["fr", "en"]
    let vocabulary = i + 3 < CommandLine.arguments.count ? CommandLine.arguments[i + 3].split(separator: ",").map(String.init) : []
    Task { @MainActor in
        do {
            let engine: any BatchSpeechEngine = ProcessInfo.processInfo.environment["FLOWCLONE_ENGINE"] == "whisper"
                ? WhisperEngine() : ParakeetEngine()
            engine.onStatus = { FileHandle.standardError.write("status: \($0)\n".data(using: .utf8)!) }
            await engine.load()
            let samples = try loadSamples(path)
            let start = Date()
            let transcript = try await engine.transcribe(samples: samples, languages: languages, vocabulary: vocabulary)
            print("[\(transcript.language ?? "?")] \(String(format: "%.2f", Date().timeIntervalSince(start)))s RAW: \(transcript.text)")
            let request = FormattingRequest(raw: transcript.text, language: transcript.language,
                                            category: .other, beforeCursor: "")
            let cleaned = await LanguageTasks.format(request, models: FormattingEngine.apple.candidates(local: nil, apple: AppleTextModel()))
            print("CLEAN: \(cleaned.text)")
            exit(0)
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }
    RunLoop.main.run()
}

//   FlowClone --eval <corpus.jsonl> [--engine apple] [--out <file.jsonl>]   → formatting evaluation
if CommandLine.arguments.contains("--eval") {
    Task { @MainActor in exit(await EvalCommand.run(arguments: CommandLine.arguments)) }
    RunLoop.main.run()
}

func loadSamples(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: input)
    let converter = AVAudioConverter(from: file.processingFormat, to: target)!
    let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1)!
    var done = false
    converter.convert(to: out, error: nil) { _, status in
        if done { status.pointee = .endOfStream; return nil }
        done = true
        status.pointee = .haveData
        return input
    }
    return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
}

let app = NSApplication.shared
let controller = MainActor.assumeIsolated { AppController() }
app.delegate = controller
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
app.run()

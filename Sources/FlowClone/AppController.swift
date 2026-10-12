import AppKit
import AVFoundation
import FlowCore
import os
import ServiceManagement

let log = Logger(subsystem: "dev.local.flowclone", category: "app")

/// Menu-bar app wiring: hotkey → capture context → record → transcribe →
/// format → paste. In Wispr Flow these stages are split between the Electron
/// main process (state machine, network, formatting) and a Swift helper
/// (hotkey, AX, paste) talking JSON over fd 3. A single native process
/// doesn't need that split.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private enum State { case loading, idle, recording, processing }

    /// Languages offered in the menu (ISO 639-1 → name). Like Wispr's `selectedLanguages`:
    /// one selected → forced; several → detected among them.
    private static let languageChoices: [(code: String, name: String)] = [
        ("fr", "Français"), ("en", "English"), ("es", "Español"), ("de", "Deutsch"), ("it", "Italiano"),
        ("pt", "Português"), ("nl", "Nederlands"), ("pl", "Polski"), ("ja", "日本語"), ("zh", "中文"),
    ]

    private let defaults = UserDefaults.standard
    private lazy var hotkey = HotkeyMonitor(key: HotkeyMonitor.Key(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .rightCommand)
    private let paster = Paster()
    private let parakeet = ParakeetEngine()
    private let whisper = WhisperEngine()
    /// Parakeet by default (best accuracy/speed on European languages); Whisper for
    /// prompt-based vocabulary and the ~100 languages Parakeet doesn't cover.
    private enum EngineChoice: String, CaseIterable {
        case parakeet, whisper
        var label: String {
            self == .parakeet ? "Parakeet v3 — fast, 25 European languages" : "Whisper large-v3 turbo — ~100 languages"
        }
        var shortName: String { self == .parakeet ? "Parakeet v3" : "Whisper large-v3 turbo" }
    }
    private var engineChoice: EngineChoice {
        get { EngineChoice(rawValue: defaults.string(forKey: "engine") ?? "") ?? .parakeet }
        set { defaults.set(newValue.rawValue, forKey: "engine") }
    }
    private var engine: any BatchSpeechEngine { engineChoice == .parakeet ? parakeet : whisper }
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let engineLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private var state = State.loading { didSet { refreshIcon(); updateActivity() } }
    /// Keeps App Nap from throttling audio capture, the speech model and the
    /// paste while a dictation is in flight. Menu-bar apps have no visible
    /// window, which is exactly when macOS naps them.
    private var activity: NSObjectProtocol?
    private var appleLocale: Locale?
    private var session: (any DictationSession)?
    private var context = FocusContext()
    private var pressedAt = Date()
    private var lastTranscript: String?
    private let setup = SetupModel()
    private let setupWindow = SetupWindowController()
    private let hud = HUDController()

    /// Wispr debounces accidental taps (DICTATION_DEBOUNCE_DELAY).
    private let minimumHold: TimeInterval = 0.3
    private var cleanupEnabled: Bool {
        get { defaults.object(forKey: "cleanup") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "cleanup") }
    }
    /// Until the local model lands (and the Formatting menu with it), the cleanup
    /// toggle maps to Apple's model or nothing.
    private var formattingEngine: FormattingEngine { cleanupEnabled ? .apple : .off }
    private let appleModel = AppleTextModel()
    /// Command Mode cascade, best first. Qwen 4B goes in front once it ships (ticket 08).
    private var commandModels: [any TextModel] { [appleModel] }
    private var languages: [String] {
        get {
            if let saved = defaults.stringArray(forKey: "languages") { return saved }
            // Default: the user's system languages that we offer, e.g. ["fr", "en"].
            let codes = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
            let offered = Set(Self.languageChoices.map(\.code))
            let picked = codes.reduce(into: [String]()) { if offered.contains($1), !$0.contains($1) { $0.append($1) } }
            return picked.isEmpty ? ["en"] : picked
        }
        set { defaults.set(newValue, forKey: "languages") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would both hear the hotkey and paste twice.
        let me = NSRunningApplication.current
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != me.processIdentifier }) {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        // Without windows macOS may also quit the app on its own ("automatic termination").
        ProcessInfo.processInfo.disableAutomaticTermination("Listening for the push-to-talk key")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        state = .loading
        setStatus("Preparing speech model…")

        hotkey.onPress = { [weak self] in Task { @MainActor in self?.keyDown() } }
        hotkey.onModeChanged = { [weak self] mode in Task { @MainActor in self?.modeChanged(mode) } }
        hotkey.onRelease = { [weak self] mode in Task { @MainActor in await self?.keyUp(mode: mode) } }
        hotkey.onInterrupt = { [weak self] in Task { @MainActor in await self?.shortcutInterrupted() } }
        for (name, model) in [("parakeet", parakeet), ("whisper", whisper)] as [(String, any BatchSpeechEngine)] {
            model.onStatus = { [weak self] status in
                if case .downloading = status {} else { log.info("\(name, privacy: .public): \(String(describing: status), privacy: .public)") }
                self?.engineChanged()
            }
        }

        let firstLaunch = !defaults.bool(forKey: "launchedBefore")
        if firstLaunch {
            defaults.set(true, forKey: "launchedBefore")
            // Like Wispr Flow, run from login so dictation is always available.
            try? SMAppService.mainApp.register()
        }
        rebuildMenu()

        Task {
            await requestPermissions()
            await prepareAppleEngine()
            await engine.load()
        }

        // Menu-bar apps have no window, so opening one looks like "nothing happened".
        // Show setup on first launch or while something is missing.
        setup.hotkeyLabel = hotkey.key.label
        setup.refresh()
        if firstLaunch || setup.microphone != .authorized || !setup.accessibility {
            showSetup()
        }
    }

    /// Double-clicking the app while it's already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSetup()
        return false
    }

    @objc private func showSetup() {
        setupWindow.show(model: setup)
    }

    // MARK: Engines

    /// Apple's engine works within seconds; it covers the time the main model takes to download.
    private func prepareAppleEngine() async {
        let locale = Locale(identifier: languages.first ?? Locale.current.identifier)
        do {
            appleLocale = try await AppleDictationSession.prepare(locale: locale)
            log.info("apple engine ready: \(self.appleLocale?.identifier ?? "?", privacy: .public)")
        } catch {
            log.error("apple engine: \(error.localizedDescription, privacy: .public)")
        }
        engineChanged()
    }

    private func engineChanged() {
        let ready = engine.isReady || appleLocale != nil
        if state == .loading, ready { state = .idle }
        setup.modelReady = ready
        let name = engineChoice.shortName
        let modelText: String = switch engine.status {
        case .idle: "\(name): waiting"
        case .downloading(let p): "\(name): downloading \(Int(p * 100))% (once)"
        case .loading: "\(name): optimizing for this Mac (first launch only)…"
        case .ready: name
        case .failed(let message): "\(name) failed: \(message)"
        }
        if case .failed(let message) = engine.status { log.error("\(name, privacy: .public): \(message, privacy: .public)") }
        let usingApple = !engine.isReady && appleLocale != nil
        setup.modelStatus = engine.isReady ? "\(name) ready"
            : usingApple ? "\(modelText). Using Apple's engine (\(appleLocale!.identifier)) meanwhile."
            : modelText
        engineLine.title = engine.isReady ? "Engine: \(name)"
            : usingApple ? "Engine: Apple (\(modelText))" : modelText
        if state == .idle { setStatus("Hold \(hotkey.key.label) to dictate · \(languageSummary)") }
    }

    private func makeSession() -> (any DictationSession)? {
        if engine.isReady { return BatchDictationSession(engine: engine, languages: languages) }
        if let appleLocale { return AppleDictationSession(locale: appleLocale) }
        return nil
    }

    /// Wispr's `dictionary` field: AX words + OCR words + first/last name + user dictionary.
    private func vocabulary() -> [String] {
        let nameParts = NSFullUserName().split(separator: " ").map(String.init)
        let screen = TextHeuristics.vocabulary(from: context.beforeText + " " + context.afterText, limit: 60)
        var seen = Set<String>()
        return (PersonalDictionary.load() + nameParts + screen).filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: Pipeline

    private func keyDown() {
        log.info("hotkey down (state: \(String(describing: self.state), privacy: .public))")
        setup.hotkeySeen = true
        guard state == .idle, let session = makeSession() else {
            if state == .loading { hud.show(.message("Speech model still loading…"), autoHideAfter: 2) }
            return
        }
        // Wispr sends DictationStart to the helper first so the AX context
        // reflects the field the user was in *before* anything changes.
        context = FocusContext.capture()
        pressedAt = Date()
        hud.model.commandMode = false
        state = .recording
        // Delay the start sound so quick shortcuts using the hotkey (⌘C) stay silent.
        Task {
            try? await Task.sleep(for: .seconds(minimumHold))
            if state == .recording {
                NSSound(named: "Tink")?.play()
                hud.show(.recording)
            }
        }

        session.audio.onLevel = { [weak self] level in self?.hud.model.push(level: level) }
        self.session = session
        let vocabulary = vocabulary()
        log.info("vocabulary: \(vocabulary.count) terms")
        Task {
            do {
                try await session.start(vocabulary: vocabulary)
            } catch {
                await fail("Couldn't start recording: \(error.localizedDescription)")
            }
        }
    }

    /// Shift joined the hold: switch the HUD to its Command Mode look. It shows
    /// as soon as the HUD does (after the tap debounce), or live if already up.
    private func modeChanged(_ mode: SessionMode) {
        guard state == .recording else { return }
        log.info("session mode: \(String(describing: mode), privacy: .public)")
        hud.model.commandMode = mode == .command
    }

    private func keyUp(mode: SessionMode) async {
        let held = Date().timeIntervalSince(pressedAt)
        log.info("hotkey up after \(held, format: .fixed(precision: 2))s (state: \(String(describing: self.state), privacy: .public))")
        guard state == .recording, let session else { return }
        self.session = nil

        if held < minimumHold {
            await session.cancel()
            state = .idle
            hud.show(.message("Hold the key while you speak"), autoHideAfter: 1.5)
            return
        }

        state = .processing
        hud.show(.processing)
        NSSound(named: "Pop")?.play()
        do {
            let started = Date()
            let transcript = try await session.finish()
            let audio = session.audio
            log.info("transcript: \(transcript.text.count) chars, language \(transcript.language ?? "?", privacy: .public), \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s; audio \(audio.buffers) buffers, \(audio.frames) frames, peak \(audio.peakLevel, format: .fixed(precision: 2))")
            guard !transcript.text.isEmpty else {
                state = .idle
                setStatus("Didn't catch that")
                hud.show(.message("Didn't catch that"), autoHideAfter: 1.5)
                return
            }
            if mode == .command {
                await runCommand(transcript)
                return
            }
            let request = FormattingRequest(raw: transcript.text, language: transcript.language,
                                            category: context.category, beforeCursor: context.beforeText)
            let text = await LanguageTasks.format(request, models: formattingEngine.candidates(local: nil, apple: appleModel)).text
            let insert = TextHeuristics.withLeadingSpaceIfNeeded(text, before: context.beforeText)
            lastTranscript = text
            paste(insert)
        } catch {
            await fail("Transcription failed: \(error.localizedDescription)")
        }
    }

    /// Command Mode: the transcript is an instruction for the selection, or for
    /// text to write at the cursor. On failure nothing is pasted, least of all
    /// the instruction itself.
    private func runCommand(_ transcript: Transcript) async {
        let request = CommandRequest(instruction: transcript.text, selection: context.selectedText,
                                     beforeSelection: context.beforeText, afterSelection: context.afterText,
                                     category: context.category, language: transcript.language)
        let started = Date()
        switch await LanguageTasks.command(request, models: commandModels) {
        case .success(let result):
            log.info("command: \(result.action == .replaceSelection ? "replace" : "insert", privacy: .public) \(result.text.count) chars via \(result.modelID, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
            lastTranscript = result.text
            // With a selection it is still active, so ⌘V replaces it (and ⌘Z undoes it).
            paste(result.text)
        case .failure(let failure):
            let message = switch failure {
            case .noModelAvailable: "No model available for Command Mode"
            case .outputRejected: "Command Mode couldn't produce usable text"
            case .emptyInstruction: "Didn't catch that"
            }
            log.info("command failed: \(String(describing: failure), privacy: .public)")
            state = .idle
            setStatus(message)
            hud.show(.message(message), autoHideAfter: 2.5)
            NSSound(named: "Basso")?.play()
        }
    }

    private func paste(_ text: String) {
        paster.paste(text) { [weak self] outcome in
            guard let self else { return }
            self.state = .idle
            log.info("paste outcome: \(outcome.rawValue, privacy: .public)")
            if outcome == .leftOnClipboard {
                self.setStatus("The text field didn't take the paste — copied to clipboard (⌘V)")
                self.hud.show(.message("Copied to clipboard — press ⌘V"), autoHideAfter: 2.5)
            } else {
                self.hud.show(.hidden)
                self.setStatus("Inserted \(text.split(separator: " ").count) words")
            }
        }
    }

    /// The hotkey was part of a shortcut (⌘C, ⌥[ …): drop the recording silently.
    private func shortcutInterrupted() async {
        guard state == .recording, let session else { return }
        self.session = nil
        await session.cancel()
        state = .idle
        hud.show(.hidden)
        log.info("recording cancelled: hotkey used in a shortcut")
    }

    private func fail(_ message: String) async {
        await session?.cancel()
        session = nil
        state = .idle
        setStatus(message)
        log.error("\(message, privacy: .public)")
        hud.show(.message(message), autoHideAfter: 3)
        NSSound(named: "Basso")?.play()
    }

    private func updateActivity() {
        let busy = state == .recording || state == .processing
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical], reason: "Dictation in progress")
        } else if !busy, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }

    // MARK: Permissions

    private func requestPermissions() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        setup.refresh()
        // Accessibility covers reading the focused field, posting ⌘V and the event tap;
        // the setup window walks the user through granting it.
        log.info("permissions at launch: axTrusted=\(AXIsProcessTrusted()) listenEvent=\(CGPreflightListenEventAccess()) postEvent=\(CGPreflightPostEventAccess())")
        guard AXIsProcessTrusted() else {
            // An event tap created without permission still "succeeds" but only sees keys
            // typed into this app, and the window server keeps treating the process as
            // untrusted (synthetic ⌘V is dropped) even after the grant. So wait for the
            // grant, then relaunch — Wispr's helper says the same: "Grant Accessibility, then relaunch".
            log.info("waiting for Accessibility before installing the keyboard listener")
            Task {
                while !AXIsProcessTrusted() { try? await Task.sleep(for: .seconds(1)) }
                log.info("Accessibility granted: relaunching")
                relaunch()
            }
            return
        }
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        if hotkey.start() {
            setup.hotkeyListening = true
            log.info("event tap created")
        } else {
            log.error("event tap creation failed although Accessibility is granted")
        }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this instance to exit so the single-instance guard lets the new one run.
        helper.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path]
        try? helper.run()
        NSApp.terminate(nil)
    }

    // MARK: Menu bar

    private var languageSummary: String {
        languages.isEmpty ? "any language" : languages.joined(separator: "/")
    }

    private func refreshIcon() {
        let (symbol, tint): (String, NSColor?) = switch state {
        case .loading: ("hourglass", nil)
        case .idle: ("mic", nil)
        case .recording: ("mic.fill", .systemRed)
        case .processing: ("ellipsis.circle", nil)
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "FlowClone")
        image?.isTemplate = tint == nil
        statusItem.button?.image = tint.flatMap { image?.withSymbolConfiguration(.init(paletteColors: [$0])) } ?? image
    }

    private func setStatus(_ text: String) {
        statusLine.title = text
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        statusLine.isEnabled = false
        engineLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(engineLine)
        menu.addItem(.separator())

        let languageMenu = NSMenu()
        for (code, name) in Self.languageChoices {
            let item = NSMenuItem(title: name, action: #selector(toggleLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = languages.contains(code) ? .on : .off
            languageMenu.addItem(item)
        }
        let languageItem = NSMenuItem(title: "Languages (\(languageSummary))", action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        let engineMenu = NSMenu()
        for choice in EngineChoice.allCases {
            let item = NSMenuItem(title: choice.label, action: #selector(selectEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = choice == engineChoice ? .on : .off
            engineMenu.addItem(item)
        }
        let engineItem = NSMenuItem(title: "Speech model", action: nil, keyEquivalent: "")
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)

        let appleAvailable = appleModel.isAvailable
        let cleanup = NSMenuItem(title: appleAvailable ? "AI cleanup (on-device)" : "AI cleanup (Apple Intelligence off)",
                                 action: #selector(toggleCleanup), keyEquivalent: "")
        cleanup.target = self
        cleanup.state = cleanupEnabled && appleAvailable ? .on : .off
        cleanup.isEnabled = appleAvailable
        menu.addItem(cleanup)

        let hotkeyMenu = NSMenu()
        for key in HotkeyMonitor.Key.allCases {
            let item = NSMenuItem(title: key.label, action: #selector(selectHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            item.state = key == hotkey.key ? .on : .off
            hotkeyMenu.addItem(item)
        }
        let hotkeyItem = NSMenuItem(title: "Push-to-talk key", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        let dictionary = NSMenuItem(title: "Edit personal dictionary…", action: #selector(editDictionary), keyEquivalent: "")
        dictionary.target = self
        menu.addItem(dictionary)

        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let setupItem = NSMenuItem(title: "Setup…", action: #selector(showSetup), keyEquivalent: ",")
        setupItem.target = self
        menu.addItem(setupItem)

        let copyLast = NSMenuItem(title: "Copy last transcript", action: #selector(copyLastTranscript), keyEquivalent: "c")
        copyLast.target = self
        menu.addItem(copyLast)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit FlowClone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        refreshIcon()
        engineChanged()
    }

    @objc private func toggleLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        var current = languages
        if let i = current.firstIndex(of: code) {
            guard current.count > 1 else { return } // keep at least one
            current.remove(at: i)
        } else {
            current.append(code)
        }
        languages = current
        rebuildMenu()
        // Apple's fallback engine is single-language: follow the first choice.
        Task { await prepareAppleEngine() }
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = EngineChoice(rawValue: raw),
              choice != engineChoice else { return }
        engineChoice = choice
        rebuildMenu()
        Task { await engine.load() } // downloads on first use; Apple's engine covers the wait
    }

    @objc private func toggleCleanup() {
        cleanupEnabled.toggle()
        rebuildMenu()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            log.error("login item: \(error.localizedDescription, privacy: .public)")
        }
        rebuildMenu()
    }

    @objc private func editDictionary() {
        NSWorkspace.shared.open(PersonalDictionary.ensureFile())
    }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = HotkeyMonitor.Key(rawValue: raw) else { return }
        defaults.set(raw, forKey: "hotkey")
        hotkey.key = key
        setup.hotkeyLabel = key.label
        rebuildMenu()
    }

    @objc private func copyLastTranscript() {
        guard let lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }
}

/// Words the recognizer should spell your way (names, jargon), one per line.
/// Wispr Flow keeps the same thing server-side (`/api/v1/dictionary/personal`).
enum PersonalDictionary {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "FlowClone/dictionary.txt")
    }

    static func load() -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func ensureFile() -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let header = "# One word or name per line. FlowClone passes these to the speech model so it spells them your way.\n"
            try? header.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
}

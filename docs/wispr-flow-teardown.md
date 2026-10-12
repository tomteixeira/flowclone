# How Wispr Flow works — static teardown

Target: `/Applications/Wispr Flow.app`, version **1.6.1102** (`com.electron.wispr-flow`), analysed 2026-10-12.
Method: static analysis only (REA + reading the unpacked bundle). Nothing was executed and no network traffic was observed,
so everything about server behaviour is inferred from client code.

| Artifact | SHA-256 / REA Evidence |
|---|---|
| `Resources/app.asar` | integrity hash from Info.plist `9d5de587…1b8e`; REA JS analysis `ev_f05d1795aaa35f6732169d46f375ab368f44c7dea4843e43ef64b365b9d27438` |
| Swift helper `Resources/swift-helper-app-dist/Wispr Flow.app/Contents/MacOS/Wispr Flow` (arm64) | `21afb12c…59ca1`; REA string searches `ev_6381021d…d142`, `ev_1c1e98df…f1581` |

Coverage limits: REA parsed all 167 JS files (1,428 modules) statically, but semantic (data-flow) analysis was skipped for the
largest bundles (`main/index.js` 9.8 MB, renderers) for memory reasons; those were read directly after `asar extract`.
The Swift helper was examined through strings and imported symbols, not decompiled function by function.

## Architecture: two processes

```
┌───────────────────────── Electron app (TypeScript, webpack) ─────────────────────────┐
│ main process: dictation state machine, mic capture (getUserMedia + AudioWorklet),     │
│ Opus encoding (opusEncoder.worker.js, opusscript wasm), gRPC client, REST client,     │
│ SQLite history (sequelize + sqlite3), Supabase auth, Sentry/PostHog                   │
└─────────────▲──────────────────────────────────────────────────────┬─────────────────┘
              │ JSON over fd 3 (spawn stdio: [pipe,pipe,pipe,pipe])     │ gRPC (flow_api.v1)
              │ framed with "|", escaped with "+"                       ▼ + HTTPS api.wisprflow.ai
┌─────────────┴────────── Swift helper (native, arm64) ──────────┐   ┌──────────── Wispr cloud ─────────────┐
│ CGEventTap hotkey, Accessibility (AX) text-field reading,      │   │ TranscribeStream: ASR → LLM format   │
│ clipboard + synthetic ⌘V paste, focus/app tracking, overlays   │   │ /llm/formatting, /llm/command_mode…  │
└────────────────────────────────────────────────────────────────┘   └──────────────────────────────────────┘
```

### Evidence: Electron ↔ Swift helper IPC
- The helper is launched from `${resources}/swift-helper-app-dist/Wispr Flow.app/Contents/MacOS/Wispr Flow`
  (log string `"Running packaged Mac Helper service"`), with `spawn(path, {stdio: ["pipe","pipe","pipe","pipe"]})`.
- Only fd 3 carries messages: `process.stdio[3].on("data", e => pushData(e))`; stdout is logged as `"Helper service stdout (non-IPC)"`.
- Framing: `pushData` splits on `Xe = "|"`, unescapes `+2 → |` and `+1 → +`, then parses
  `{HelperAPIRequest: …}` or `{HelperAPIResponse: …}` (types generated with quicktype).
- 70 request types and 26 response types. The dictation path uses:
  `KeypressEvent{eventType,key,index}` (helper→Electron), `DictationStart{captureMarkerContext}`,
  `TextBoxInfo{beforeText,selectedText,afterText,contents,isEditable,accessibilityIsFunctioning}`,
  `AppInfoUpdate{appName,bundleId,…}`, `PasteText{text,htmlText,pasteId}`, `PasteOutcome{pasteId,success,timeElapsedMs}`,
  `SimulateKeyPress{keycode,flags}`, `GetSelectedTextViaCopy`.

### Evidence: native hotkey, context and paste (Swift helper)
- Imports: `CGEventTapCreate`, `CGEventTapEnable`, `CGEventPost`, `CGEventCreateKeyboardEvent`, `AXUIElementCreateSystemWide`,
  `AXUIElementCopyAttributeValue`, `AXUIElementSetAttributeValue`, `AXObserverCreate`, `AXIsProcessTrustedWithOptions`.
- Strings: `AXFocusedUIElement`, `AXSelectedTextRange`, `AXSelectedTextMarkerRange`, `"Caps Lock flagsChanged ignored: HID owns the key"`,
  `tapCreateFailed`.
- Paste: `"Saved pasteboard types: "`, `"Restoring pasteboard contents in "`, `org.nspasteboard.ConcealedType`,
  `NSPasteboardItemDataProvider`, `"Started timer to detect failed pastes"`,
  `"Delayed clipboard timeout -- failed paste likely - no app requested data within "`,
  `"Failed Timeout timer cancelled - paste succeeded (data was requested)"`, `"Beginning pasteText with delimiters."`.
  → The helper puts the text on the pasteboard **lazily**, sends ⌘V, and treats "the target app requested the data" as paste success.

### Evidence: transcription protocol (`flow_api.v1`, protobuf-ts + @grpc/grpc-js)
- `service TranscriptionService { rpc Transcribe(Request) returns (Response); rpc TranscribeStream(stream Request) returns (stream Response); }`
- `Request { oneof: init=1 | context=2 | payload=3 | commit=4 }` — the client sends `init` (Metadata + Preferences),
  `context`, a series of audio `payload`s, then `commit` and `requests.complete()` (`"Final audio received, ending gRPC stream"`).
- `Metadata { user_id, session_id, request_id, audio_encoding (WAV|OPUS), environment, client, … }`
- `Payload { oneof audio: AudioPackets{items} | AudioFile{data} }` — Opus packets from `opusEncoder.worker.js`.
- `Context { app, textbox{contents,before_text,selected_text,after_text}, vocabulary: DynamicVocabulary{screen_content_ax,
  screen_content_ocr, variable_names, file_names}, content_text, content_html, screenshot, conversation, … }`
- `Preferences { user, language, vocabulary: StaticVocabulary{dictionary_personal, dictionary_team…}, replacements{…snippets…},
  style_config{general_style, tagging, signature, editing_strength} }`
- `Response { result | state | all_states | heartbeat }`; `State.progress {transcriber, formatter, post_processing_finished}`,
  `raw_text`, `formatted_text`, `candidate_beams`; `Result.output: Transcription{html, plaintext, languages, confidence}`,
  `response_time{transcribe, format, external_asr_time, external_llm_time…}`, `format_skip_reason`.
  → Server-side two-stage pipeline: ASR, then LLM formatting conditioned on app/textbox/vocabulary/style.
- Hosts: `https://api.wisprflow.ai`, `https://api-east.wisprflow.ai`, websockets `wss://api.wisprflow.ai/` (used for meetings
  `api/v1/meetings/transcribe`, sync `/api/v1/sync/ws`, `api/v1/voice-actions/realtime`). gRPC response headers `x-replica-id`, `x-proxy-region`.
- REST LLM endpoints: `/llm/formatting` (`model_name: "openpipe:llama3-1-8b-12-09-2024"`, or `"openpipe:llama3-1-05-21-data-email"`
  for email apps), `/llm/format_non_english`, `/llm/command_mode {full_text, selected_text, instruction}`, `/llm/chat`.

### Evidence: ASR backends and languages
- `Result.transcript_origin` is validated against `["", "internal", "external", "internal_experimental", "canto_1.0",
  "canto_1.0.1", "canto_1.1"]` → an in-house ASR model ("Canto") plus an external provider; `ResponseTime` reports
  `external_asr_time` and `external_llm_time` separately. LLM completion providers enum: `GROQ`, `OPENAI`.
- Fallback ASR: `transcribeOpenAI()` → `POST /llm/asr {audio, language, prompt}` (also `/llm/asr_audio_chunks`).
  `language` = the user's only selected language if exactly one is selected, else `prevDetectedLanguage()` — a
  Whisper-style API contract.
- `transcribeAndFormat()` → `POST /llm/api {audio, properties: {app_type, language, before_text, after_text,
  selected_text, dictionary}}` where `dictionary` = `[...axParsedWords, ...ocrParsedWords, firstName, lastName,
  ...dictionaryContext]`, deduplicated and truncated. Screen OCR goes through `POST /llm/ocr {image}`.
- `Preferences.language` is a *repeated* enum; user settings hold `usedLanguages`, `selectedLanguages`,
  `effectiveLanguages`. Non-English text is formatted by `POST /llm/format_non_english {app_type, content,
  detected_language, user_languages}`.
- Personal/team dictionaries live server-side (`/api/v1/dictionary/personal`, `/team`); edits after a paste feed
  `/llm/extract_edited_words` to learn new words.

## End-to-end dictation flow (inferred from the above)
1. Swift helper's CGEventTap sees the push-to-talk key → `KeypressEvent` to Electron.
2. Electron sends `DictationStart`; helper replies with AX context (`TextBoxInfo`, `AppInfoUpdate`).
3. Electron captures the mic (`getUserMedia` + AudioWorklet), Opus-encodes in a worker, opens `TranscribeStream`,
   sends `init` + `context` and streams `payload`s while the key is held (heartbeats report `audio_received_seconds`).
4. Key up → `commit`; server returns `Result` with ASR + LLM-formatted text. Taps shorter than a debounce threshold are discarded.
5. Electron sends `PasteText` → helper does pasteboard save → lazy write → ⌘V → success detection → restore → `PasteOutcome`.
6. Transcript stored locally in SQLite (`transcriptEntityId`), later edits tracked (`UpdateEditedText`) to learn vocabulary.

## Unknowns
- Which ASR model the server uses and how formatting is prompted (server-side; not in the client).
- Exact default hotkey and debounce value were not extracted (the FlowClone defaults are design choices).
- Swift helper control flow was not decompiled; paste behaviour is inferred from log strings + imports.

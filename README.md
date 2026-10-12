# FlowClone

Hold a key, talk, release — cleaned-up text appears in whatever app you're typing in.
A native macOS take on Wispr Flow's dictation (see [docs/wispr-flow-teardown.md](docs/wispr-flow-teardown.md)),
fully on-device: **NVIDIA Parakeet TDT 0.6B v3** (FluidAudio, CoreML) for speech — 25 European languages, ~0.1 s
per sentence — with **Whisper large-v3 turbo** (WhisperKit) selectable in the menu for prompt-based vocabulary and
~100 languages. Apple's `DictationTranscriber` covers the first launch while the model downloads, and the
`FoundationModels` on-device LLM does the cleanup. No account; network only for the one-time model download.

Requires macOS 26 (Apple Intelligence enabled for the AI cleanup step; without it, raw transcripts are pasted).

## Run
```sh
scripts/build-app.sh --install   # builds, replaces /Applications/FlowClone.app, launches it
```
Languages, push-to-talk key, AI cleanup, personal dictionary and "Open at login" are in the menu-bar menu.
Check transcription without the UI: `.build/debug/FlowClone --transcribe file.wav fr,en Kameleoon,Sarah`
(`FLOWCLONE_ENGINE=whisper` to test Whisper). The last dictation is kept in `~/Library/Application Support/FlowClone/last-recording.wav`.
FlowClone has no Dock icon or main window: it lives in the menu bar (🎙 icon, top right). A setup window opens on
first launch, whenever a permission is missing, and when you open the app again while it's running. Grant
**Microphone** and **Accessibility** there; the on-device speech model downloads automatically. Then hold
**Right Command (⌘)** and speak (Right Option or Fn can be chosen from the menu-bar icon). Pressing another key
while holding it (⌘C…) counts as a shortcut and cancels the recording.

If you pick Fn and it opens the emoji picker, switches input source or starts system dictation, set
System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**.
Builds are signed with a requirement pinned to the bundle identifier, so permissions survive rebuilds.

## Evaluating the formatting step
```sh
swift build && .build/debug/FlowClone --eval eval/formatting-corpus.jsonl --engine apple --out eval-apple.jsonl
```
Runs every case of a corpus (JSONL) through the FlowCore formatting module with one model, writes one JSON
record per case (`input`, `output` as pasted, verbatim `modelOutput`, `model`, `outcome`, `latencyMs`, `failures`)
and prints p50/p95 latency, load time (a first warm-up call; for MLX models, download + load + kernel warm-up), peak memory of the process (Apple's model runs
out of process, so only in-process models show up there), guard pass rate and rule-check failures. Per-case
progress goes to stderr. `--engine` takes what `FLOWCLONE_LLM` takes (`apple`, `qwen3-1.7b`, `qwen3-4b` or a Hugging
Face repo id `org/name[@revision]`, run with MLX) and defaults to `FLOWCLONE_LLM`, then `apple`. MLX models need
`scripts/build-mlx-metallib.sh` once after building, which puts `mlx.metallib` next to the binary.

A corpus line needs `id` and `raw`; `language`, `category` (`email`, `chat`, `code`, `document`, `other`),
`beforeCursor`, `tags` and `expect` are optional. `expect` holds `contains` (case-sensitive substrings),
`notContains` (case-insensitive, whole words) and `endsWith`. Rule checks judge the model's own output when there
is one, even if the guards rejected it: `guards_rejected`, `model_error`, `model_unavailable`, `answered_question`
(a dictated question lost its `?`), `language_changed` (French/English detection on 4+ words) and `expect_*`.

`eval/formatting-corpus.jsonl` holds 80 hand-written cases (40 French, 40 English: fillers, self-corrections,
questions, command-like dictations, emails, chat, code, proper nouns, very short inputs).
`eval/baselines/` holds the Apple and Qwen3 1.7B baselines (`<engine>.jsonl`, `<engine>.summary.txt`). Judge an output file
qualitatively by asking Claude Code to read it in a session.

## How it maps to Wispr Flow
| Stage | Wispr Flow | FlowClone |
|---|---|---|
| Hotkey | CGEventTap in Swift helper → `KeypressEvent` | `HotkeyMonitor` (CGEventTap, flagsChanged + keyDown) |
| Context | AX `TextBoxInfo` / `AppInfoUpdate` | `FocusContext` (AX focused element, before/selected/after) |
| Vocabulary | `DynamicVocabulary` from screen text | `TextHeuristics.vocabulary` → `AnalysisContext.contextualStrings` |
| ASR | Opus → gRPC `TranscribeStream` → in-house "Canto" / external ASR | `ParakeetEngine` (default) or `WhisperEngine`, on-device |
| Language | `selectedLanguages`: one → forced, several → detected | same, detection restricted to selected languages |
| Vocabulary | `dictionary` = AX + OCR words + name + personal dictionary | same minus OCR: Whisper prompt tokens, or near-miss correction for Parakeet |
| Formatting | `/llm/formatting` (fine-tuned Llama 3.1 8B) | `Formatter` (on-device model, greedy, output guards) |
| Insert | lazy pasteboard + ⌘V + success detection + restore | `Paster` (same technique) |

## Test
```sh
swift test
```

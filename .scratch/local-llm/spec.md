# Spec: Local LLM layer (Qwen3 via MLX) — better formatting + Command Mode

Status: ready-for-agent

## Problem Statement

FlowClone's cleanup step runs on Apple's on-device foundation model. Two things keep it from feeling like Wispr Flow:

- **Quality.** Filler words survive, punctuation is uneven, spoken self-corrections ("2 no actually 3") are not always applied, and the model sometimes answers or comments on the dictation instead of cleaning it up. The output guards catch the worst cases, but they then fall back to the raw transcript, so the user gets no cleanup at all.
- **Dependence on Apple Intelligence.** Without Apple Intelligence enabled there is no cleanup at all, and the model is a black box that can't be swapped, compared or fine-tuned.

FlowClone also lacks Wispr Flow's **Command Mode**: select text, speak an instruction ("make this more formal", "translate to English", "write an email moving the meeting to Thursday"), and get the result in place.

## Solution

Add a local LLM layer that runs Qwen3 models in-process with MLX Swift, downloaded once like the speech models:

- **Formatting** uses **Qwen3 1.7B** (4-bit, thinking disabled). It reuses today's formatting contract: same inputs, same app-category styles and same output guards, with French and English examples.
- **Command Mode** uses **Qwen3 4B** (4-bit, preferably the non-thinking Instruct-2507 variant if it is published for MLX). The user holds **Shift + the push-to-talk key** and speaks an instruction. If text is selected, the result replaces the selection. If nothing is selected, the generated text is inserted at the cursor.
- **Fallback cascade.** For both tasks the order is Qwen, then Apple's model, then nothing. For formatting, "nothing" means the raw transcript is pasted. For Command Mode, "nothing" means a HUD message and nothing is pasted.
- **Evidence before default.** An evaluation harness compares Qwen 1.7B with Apple's model on a hand-written French/English corpus plus, optionally, real dictations from an opt-in local journal. Qwen becomes the default formatter only if it matches or beats Apple's model on quality within the latency budget. Otherwise Apple stays the default formatter, Qwen remains the fallback, and fine-tuning or other models are explored next.

Latency targets for the LLM step: under 400 ms for a sentence and under 1.2 s for a 30-second paragraph, on an M5 with 16 GB.

## User Stories

### Formatting

1. As a dictating user, I want filler words (um, uh, euh, genre, like, you know) removed, so that my text reads as if I had typed it.
2. As a dictating user, I want spoken self-corrections applied ("à 14h non 15h" becomes "à 15h"), so that I don't have to fix them by hand.
3. As a dictating user, I want correct punctuation and capitalization, including French typography such as the space before "?", so that the text is ready to send.
4. As a dictating user, I want questions to stay questions and commands to stay commands, so that the model never answers or obeys what I dictate.
5. As a dictating user, I want the cleanup to never add words, facts or apologies I didn't say, so that I can trust what gets pasted.
6. As a French speaker, I want French dictation cleaned up in French and never translated, so that my messages stay in the language I spoke.
7. As a bilingual user, I want English and French to be handled equally well, so that I can switch languages between dictations.
8. As a user writing an email, I want full sentences with greeting and sign-off on their own lines, so that the email is well formed.
9. As a user in a chat app, I want casual, concise text, so that my messages don't sound stiff.
10. As a user in a code editor or terminal, I want technical terms kept exactly as spoken and no added prose, so that my code and commands aren't corrupted.
11. As a user, I want the text before my cursor used as context, so that the cleanup continues my sentence consistently.
12. As a user, I want my personal dictionary and on-screen vocabulary respected after cleanup, so that names like "Kameleoon" stay spelled my way.
13. As a user, I want very short or trivial dictations to skip the LLM, so that they paste instantly.
14. As a user, I want a sentence cleaned up within about 400 ms of releasing the key, so that dictation feels instant.
15. As a user, I want a 30-second paragraph cleaned up within about 1.2 s, so that long dictations don't feel slow.
16. As a user, I want the raw transcript pasted whenever the model output fails the guards, so that I never lose my words.

### Model availability and fallback

17. As a user without Apple Intelligence, I want AI cleanup to work anyway, so that FlowClone doesn't depend on a system feature I can't or won't enable.
18. As a new user, I want cleanup to work right away through Apple's model while the Qwen model downloads, so that the app is useful from the first minute.
19. As a new user, I want the formatting model downloaded on first launch and the Command Mode model downloaded in the background right after, so that both are ready before I need them.
20. As a user, I want to see download progress for the language models, so that I know when the local cleanup is ready.
21. As a user on a flaky connection, I want interrupted model downloads to resume or retry, so that I don't end up with a broken model.
22. As a user with neither Qwen nor Apple's model available, I want the raw transcript pasted, so that dictation still works.
23. As a user, I want models stored next to the speech models in Application Support, so that they're easy to find and delete.

### Memory and residency

24. As a user with 16 GB of RAM, I want the language models to stay out of memory when I'm not dictating, so that they don't slow down my other apps.
25. As a user, I want the needed model to start loading as soon as I press the push-to-talk key, so that loading overlaps with my speech and adds little or no latency.
26. As a user, I want a model unloaded after about 15 minutes of inactivity, so that idle memory is reclaimed.
27. As a user, I want Command Mode to load only the 4B model and formatting only the 1.7B model, so that memory use matches the task.

### Command Mode

28. As a user, I want to hold Shift together with my push-to-talk key to enter Command Mode, so that speaking an instruction is never confused with dictating text.
29. As a user, I want to be able to press Shift at any moment before releasing the push-to-talk key, so that I don't have to coordinate both keys at the start.
30. As a user, I want the HUD to clearly show that I'm in Command Mode, so that I know my speech will be treated as an instruction.
31. As a user, I want other shortcuts (⌘C, ⌥⇧…) pressed while holding the push-to-talk key to still cancel the recording, so that adding Shift doesn't break today's shortcut detection.
32. As a user with text selected, I want to say "make this more formal" and have the selection replaced with the rewritten text, so that I can edit by voice.
33. As a user with text selected, I want to say "translate this to English" and get the translation, so that I can translate in place.
34. As a user with text selected, I want to say "summarize this in three bullet points" and get the summary in place, so that I can condense text quickly.
35. As a user with text selected, I want to say "fix the grammar" and get a corrected version, so that I can proofread by voice.
36. As a user with no selection, I want to say "write an email to move the meeting to Thursday" and have the text inserted at my cursor, so that I can draft by voice.
37. As a user, I want the result written in the language of the selection unless my instruction explicitly asks for a translation, so that rewrites don't change language unexpectedly.
38. As a user replying to an email, I want the text around my cursor and the app type taken into account, so that the generated reply fits the conversation and the medium.
39. As a user, I want to undo a Command Mode replacement with ⌘Z, so that a bad result is one keystroke away from being reverted.
40. As a user, I want no extra wrapping in the Command Mode output ("Here is the rewritten text:", quotes, code fences), so that only the result is pasted.
41. As a user, I want an empty or runaway Command Mode output rejected, with a HUD message instead of a paste, so that my selection is never destroyed by garbage.
42. As a user, I want Command Mode to fall back to Apple's model when Qwen 4B isn't available yet, so that the feature works during the first download.
43. As a user, I want a HUD message ("Model downloading…") when no model can run Command Mode, so that I understand why nothing happened and my instruction isn't pasted as text.

### Settings

44. As a user, I want a Formatting menu with **Auto** (Qwen, else Apple), **Apple** and **Off**, so that I can choose the engine or disable cleanup. This replaces today's "AI cleanup" toggle.
45. As an existing user who had AI cleanup turned off, I want that choice carried over as **Off**, so that upgrading doesn't change my behavior unexpectedly.
46. As a user, I want no model picker in the menu, so that the settings stay simple.

### Dictation journal

47. As a user, I want an opt-in "Keep dictation journal" toggle, off by default, so that nothing is logged unless I choose it.
48. As a user who opted in, I want each formatting run logged with the raw text, formatted text, language, app category, model, latency and the 300 characters before the cursor, so that real cases can be replayed in the evaluation.
49. As a user who opted in, I want each Command Mode run logged with the instruction, selection, context, result, model and latency, so that Command Mode can be evaluated too.
50. As a user, I want a "Clear journal" menu item, so that I can delete what was logged at any time.
51. As a user, I want the journal stored locally only, so that my text never leaves the machine.

### Evaluation (developer)

52. As the developer, I want an evaluation command that runs a JSONL corpus through a chosen engine (Qwen 1.7B, Qwen 4B, Apple, or any MLX model id) and writes a JSONL of outputs, so that I can compare models on the same inputs.
53. As the developer, I want each run to report p50/p95 latency, peak memory and model load time, so that I can check the latency budget.
54. As the developer, I want automatic rule checks per case (guards passed, language kept, no answered question, ending punctuation, expected substrings present or absent), so that regressions are caught without reading every output.
55. As the developer, I want a hand-written corpus of about 80 French/English cases covering fillers, self-corrections, questions, command-like dictations, emails, chat, code and proper nouns, so that the comparison starts on day one.
56. As the developer, I want journal entries convertible into corpus cases, so that the corpus grows with real usage.
57. As the developer, I want the output JSONL readable by Claude Code in a session for qualitative judging, so that I get a quality score without an API key.
58. As the developer, I want an environment variable to force a specific language model in the app and in the CLI, so that I can test any candidate without a UI picker.
59. As the developer, I want the existing transcription command to accept that variable too, so that I can test the full audio → text → cleanup pipeline with any model.

## Implementation Decisions

### Runtime and models
- Inference runs in-process with **MLX Swift** (the MLX LLM libraries from Apple's `mlx-swift-examples` / `mlx-swift-lm`), added as a Swift package dependency next to WhisperKit and FluidAudio.
- Models are 4-bit MLX conversions from the `mlx-community` Hugging Face organization: Qwen3 1.7B for formatting, Qwen3 4B for Command Mode (the Instruct-2507 variant if it is available, otherwise base Qwen3 4B with thinking disabled). Check that these repos exist when implementing.
- Qwen3's thinking mode is always disabled (`enable_thinking=false` in the chat template, or the non-thinking variant). Decoding is greedy for formatting. Command Mode may use a low temperature, but greedy is the default until the evaluation says otherwise.
- Model weights are stored under the existing FlowClone models directory in Application Support.

### `TextModel` seam (FlowCore)
- A new protocol in FlowCore abstracts any language model: it receives instructions (system prompt), a user prompt and generation options (max tokens, sampling), and returns text asynchronously. It can report that it is unavailable, and it can throw.
- Implementations: an MLX-backed model (one instance per model id) and an Apple Foundation Models–backed model. Both live in the app target and stay as thin as possible: no prompt logic, no guards.
- A deep module in FlowCore owns everything else and is the only thing the app calls:
  - **Formatting**: takes the raw transcript, language, app category, before-cursor text and vocabulary, and returns the text to paste. It owns the formatting prompt (moved out of today's `Formatter`, extended with French examples), the skip heuristic, the output guards and the fallback cascade.
  - **Command Mode**: takes the instruction transcript, the selected text (possibly empty), before/after text, app category and selection language, and returns either the text to paste or a typed failure (no model available, output rejected). It owns the Command Mode prompt, its guards (non-empty, model wrapping stripped, length capped relative to selection or instruction) and the cascade.
  - **Engine choice**: an ordered list of candidate models per task (Auto: Qwen then Apple; Apple: Apple only; Off: none), resolved from settings and availability.
- The existing `Formatter` becomes a thin adapter, or is removed in favor of the FlowCore module.

### Model lifecycle (app target)
- A model manager owns download, load and unload for the MLX models.
- Download: Qwen 1.7B on first launch (alongside the speech model), then Qwen 4B in the background once the 1.7B is in place. Progress appears in the setup window or the menu, the same way the speech model download does.
- Load: when the push-to-talk key goes down, start loading the 1.7B. When Command Mode is detected (Shift), start loading the 4B instead. Loading overlaps with recording.
- Unload: each model is released after about 15 minutes without use.
- While a model is downloading or loading and isn't ready when the transcript arrives, the cascade falls through to Apple's model instead of waiting. The exception is a load already in progress that will finish within the latency budget, in which case it waits for that load. The cutoff is tuned during implementation.

### Hotkey state machine seam (FlowCore)
- The event-interpretation logic of `HotkeyMonitor` moves into a pure state machine in FlowCore. It consumes simplified key events (flagsChanged with keycode and flags, keyDown) and emits `press`, `release(mode: dictation | command)` and `interrupt`.
- New rule: **Shift** (either side) pressed or held while the push-to-talk key is down switches the session to Command Mode instead of interrupting. Any other modifier or any keyDown still interrupts, as today. Shift already held when the push-to-talk key goes down also counts as Command Mode. Releasing Shift before the push-to-talk key keeps Command Mode, since the switch is sticky for that session.
- The state machine also emits a mode-changed event so that the HUD can switch to its Command Mode look while recording.
- `HotkeyMonitor` keeps only the CGEventTap plumbing and forwards events to the state machine.

### Command Mode flow (app target)
- The focus context is captured at key-down as today. It already reads before, selected and after text through AX.
- On release in Command Mode, the transcript goes to the FlowCore Command Mode entry point, together with the selection, about 300 characters of context on each side and the app category.
- With a selection, the result is pasted over it by the existing `Paster` (the selection is still active, so ⌘V replaces it). With no selection, it is inserted at the cursor, using the same leading-space logic as dictation.
- A rejected result or a missing model shows a HUD message and pastes nothing.

### Settings
- The `cleanup` boolean in UserDefaults is replaced by a formatting-engine setting: `auto`, `apple` or `off`. Migration: `cleanup=false` becomes `off`, anything else becomes `auto`.
- A developer override environment variable (`FLOWCLONE_LLM`) forces a model id for the app and the CLI, mirroring `FLOWCLONE_ENGINE`.
- **Default formatting engine:** `auto` resolves to Qwen first only if the evaluation shows Qwen 1.7B matching or beating Apple's model within the latency budget. Until then, `auto` resolves to Apple first and Qwen second. Make this ordering a single, easily flipped constant.

### Dictation journal
- A Codable record type in FlowCore with one variant for formatting and one for Command Mode, holding the fields listed in user stories 48–49. It is encoded as one JSON object per line.
- It is written by the app to a JSONL file in Application Support, only when the opt-in toggle is on. The menu gets "Keep dictation journal" (off by default) and "Clear journal".
- Journal records can be converted into evaluation corpus cases. The evaluation reuses the record shape as input, with optional `expect` fields.

### Evaluation harness
- New CLI mode next to `--transcribe`: given a corpus JSONL (formatting or Command Mode cases) and a model selection, it runs every case through the FlowCore module with the real models and writes an output JSONL. It also prints a summary: p50/p95 latency, model load time, peak memory, guard-pass rate and rule-check failures.
- The hand-written corpus (about 80 cases, French and English) lives in the repo with the evaluation tooling.
- Qualitative judging is done by Claude Code in a session from the output JSONL. There is no API integration for now.

## Testing Decisions

- Good tests here check **external behavior through the two seams**: given these inputs and these fake models, the text to paste (or the failure) is X; given this sequence of key events, the emitted events are Y. They never assert on prompt wording or internal call order, except where the prompt content is itself the contract (the dictation is fenced as data, the language rule is present).
- **Formatting / Command Mode module** (FlowCore, fake `TextModel`s):
  - The cascade: first model unavailable or throwing falls through to the second, and no model at all gives the raw transcript (formatting) or a typed failure (Command Mode).
  - Guards: a model output that answers the question, adds content, is empty or is wrapped gets rejected, and the next fallback or the raw text is used.
  - Engine settings: `off` never calls a model, and `apple` never calls the MLX model.
  - Command Mode: an empty selection yields an insertion, a selection yields a replacement, and a runaway output is rejected.
  - The skip heuristic bypasses the models.
- **Hotkey state machine** (FlowCore, pure): press/release gives dictation; Shift during hold gives command; Shift before press gives command; Shift released before key release still gives command; ⌘C or another modifier during hold gives interrupt; keyDown after the Shift switch gives interrupt; the right/left variants of the push-to-talk key are told apart as today.
- **Journal records**: encoding and decoding round-trip, and one record per line.
- **Prior art**: `TextHeuristicsTests` (guards and heuristics, including cases observed from the on-device model) and `VocabularyCorrectionTests`, both plain XCTest against FlowCore with no system permissions.
- **Not unit tested**: MLX and Apple model adapters, download and residency management, Paster and HUD. These are covered by the evaluation harness (real models, latency and memory) and by a manual check in the app.

## Out of Scope

- LoRA fine-tuning of the formatting model. It is the planned follow-up if Qwen 1.7B loses to Apple's model on the evaluation.
- Wispr-style `style_config` (general style, editing strength) and per-user style settings.
- Learning vocabulary from post-paste edits (`/llm/extract_edited_words`).
- Languages other than French and English as quality targets. They are best effort: guards apply, and the fallback is the raw text.
- A model picker in the UI.
- An automated LLM judge through the Anthropic API.
- A preview or confirmation step for Command Mode results.
- Screen OCR vocabulary.

## Further Notes

- Delivery order (each step shippable on its own):
  1. The `TextModel` seam, the FlowCore formatting module, the MLX integration with Qwen 1.7B, and the evaluation harness with the hand-written corpus. Compare against Apple's model before changing app behavior.
  2. The Auto engine with the fallback cascade, model download, load and unload, and the Formatting menu with settings migration.
  3. Command Mode with Qwen 4B: hotkey state machine, HUD mode, context, insertion and replacement.
  4. The dictation journal with its menu toggles.
- Hardware reference for budgets: Apple M5, 16 GB RAM, macOS 26.
- Wispr Flow's equivalents, from `docs/wispr-flow-teardown.md`: `/llm/formatting` (fine-tuned Llama 3.1 8B), `/llm/format_non_english`, `/llm/command_mode {full_text, selected_text, instruction}`.
- Update the README's "How it maps to Wispr Flow" table once steps 1–3 land.

# 06: Auto engine in the app — download, residency, Formatting menu

**What to build:** In the real app, formatting goes through the cascade (per the default-order constant: Qwen 1.7B and Apple, then raw). Qwen 1.7B downloads on first launch with visible progress, loads when the push-to-talk key goes down, and unloads after about 15 minutes idle. The menu's "AI cleanup" toggle becomes a Formatting menu: Auto / Apple / Off. See the spec, sections "Model lifecycle" and "Settings".

**Blocked by:** 04 (MLX adapter + Qwen3 1.7B)

**Status:** resolved

- [x] Qwen 1.7B downloads on first launch alongside the speech model; progress shown in the setup window or menu; failures retry
- [x] Until the model is ready, formatting uses the next engine in the cascade (no waiting on a download)
- [x] Model load starts on push-to-talk key-down and overlaps with recording
- [x] Model is released after ~15 minutes without use; next dictation reloads it
- [x] If a load is still in progress when the transcript arrives, the app waits only within the latency budget, else falls through
- [x] Formatting menu with Auto / Apple / Off replaces the "AI cleanup" toggle; menu works without Apple Intelligence
- [x] Settings migration: `cleanup=false` becomes Off, anything else becomes Auto
- [ ] Manual check with Apple Intelligence disabled: dictation is cleaned up by Qwen

## Implementation notes

- Policy lives in FlowCore: `FormattingEngine.fromSettings` (migration), `LocalModelResidency` + `ResidencyPolicy.standard` (15 min idle, 0.75 s wait budget, 4 s assumed load until measured), `FormattingEngine.preloadsLocal`, `DownloadRetry`.
- App: `LocalModelManager` (downloads its specs in order with retry, `prepare(spec)` on key-down, idle unload timer); a managed `MLXTextModel` reports `isAvailable` from its residency and waits for an in-progress load only within the budget.
- Key-down preloads Qwen only when the cascade would reach it (with `autoOrder` = Apple first: only when Apple Intelligence is unavailable). If ticket 05 flips `autoOrder`, Qwen preloads on every dictation.
- Ticket 08: pass `[LocalModels.formatting, LocalModels.commandMode]` to `LocalModelManager`, call `prepare(LocalModels.commandMode)` on mode change, and put `localModels.model(for: LocalModels.commandMode)` ahead of Apple in `commandModels`.
- Not yet checked by hand: the manual check with Apple Intelligence disabled, download progress in the setup window and menu, idle unload.

## Comments

Merged into `local-llm`; `swift build`, `swift test` (116 tests, 0 failures) and `scripts/build-app.sh` pass. Not yet verified in the running app:

- Cleanup by Qwen with Apple Intelligence disabled
- Download progress shown in the setup window and the menu
- Retry after a failed download
- 15-minute idle unload, then reload on the next dictation
- Tuning of the 0.75 s wait budget for an in-progress load

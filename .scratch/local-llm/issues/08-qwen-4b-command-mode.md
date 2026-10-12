# 08: Qwen3 4B for Command Mode

**What to build:** Qwen3 4B (4-bit, Instruct-2507 if available) downloads in the background once Qwen 1.7B is in place, loads as soon as Shift switches a session to Command Mode, sits first in the Command Mode cascade ahead of Apple's model, and unloads after inactivity like the 1.7B.

**Blocked by:** 06 (Auto engine in the app), 07 (Command Mode end to end)

**Status:** resolved

- [ ] Background download starts after the 1.7B is ready; progress visible; failures retry
- [x] Command Mode cascade: Qwen 4B, then Apple, then HUD message
- [x] Load starts on the mode-changed event (Shift detected), not on key-down; formatting sessions never load the 4B
- [x] 4B released after ~15 minutes without use, independently of the 1.7B
- [ ] While the 4B is downloading, Command Mode keeps working through Apple's model
- [ ] Manual check with Apple Intelligence disabled: Command Mode works through Qwen 4B

## Notes

- FlowCore `LocalModelPlan` (from `FLOWCLONE_LLM`): download order (1.7B, then 4B), the model each session mode loads (dictation → 1.7B, command → 4B), the residency policy per model and the Command Mode cascade (Qwen 4B, then Apple; an override forces one model or none for both tasks).
- `ResidencyPolicy.commandMode`: 15 min idle, 4 s wait budget, 6 s assumed load. The 4B load starts at Shift, so it is often still loading at release; Command Mode has no 400 ms target and its generation already takes a second or more, so a load expected to end within 4 s is waited for, otherwise Apple answers.
- App: the 4B loads on `modeChanged(.command)`; with Shift already held at key-down the 1.7B preload is skipped. The menu shows a "Command Mode Qwen3 4B" status line (download progress, retries).
- `swift build`, `swift test` (126 tests) and `scripts/build-app.sh` pass. Not yet verified in the running app: the download and its progress/retry in the menu, loading at Shift, the 4 s budget in practice, the independent 15-minute unload, Command Mode via Apple while the 4B downloads, and Command Mode with Apple Intelligence disabled.

## Comments

- Merged into `local-llm` (`swift build`, `swift test` with 135 tests, and `scripts/build-app.sh` pass). The unticked items need a manual check in the running app.

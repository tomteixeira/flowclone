# 06: Auto engine in the app — download, residency, Formatting menu

**What to build:** In the real app, formatting goes through the cascade (per the default-order constant: Qwen 1.7B and Apple, then raw). Qwen 1.7B downloads on first launch with visible progress, loads when the push-to-talk key goes down, and unloads after about 15 minutes idle. The menu's "AI cleanup" toggle becomes a Formatting menu: Auto / Apple / Off. See the spec, sections "Model lifecycle" and "Settings".

**Blocked by:** 04 (MLX adapter + Qwen3 1.7B)

**Status:** ready-for-agent

- [ ] Qwen 1.7B downloads on first launch alongside the speech model; progress shown in the setup window or menu; failures retry
- [ ] Until the model is ready, formatting uses the next engine in the cascade (no waiting on a download)
- [ ] Model load starts on push-to-talk key-down and overlaps with recording
- [ ] Model is released after ~15 minutes without use; next dictation reloads it
- [ ] If a load is still in progress when the transcript arrives, the app waits only within the latency budget, else falls through
- [ ] Formatting menu with Auto / Apple / Off replaces the "AI cleanup" toggle; menu works without Apple Intelligence
- [ ] Settings migration: `cleanup=false` becomes Off, anything else becomes Auto
- [ ] Manual check with Apple Intelligence disabled: dictation is cleaned up by Qwen

# 02: Push-to-talk state machine in FlowCore (prefactor)

**What to build:** Extract the key-event interpretation of `HotkeyMonitor` into a pure state machine in FlowCore that consumes simplified key events (flagsChanged with keycode + flags, keyDown) and emits `press`, `release` and `interrupt`. `HotkeyMonitor` keeps only the CGEventTap plumbing. Behavior is unchanged. See the spec, section "Hotkey state machine seam (FlowCore)".

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [x] State machine lives in FlowCore with no AppKit/CoreGraphics dependency (plain keycode and flag bits)
- [x] Supports the three push-to-talk keys (Right Command, Right Option, Fn) with right/left told apart as today
- [x] Tests: press then release gives `press`, `release`; keyDown while held gives `interrupt` and no `release`; another modifier while held gives `interrupt`; repeated flagsChanged with no state change emits nothing
- [x] `HotkeyMonitor` forwards events to the state machine and maps its outputs to the existing callbacks
- [ ] Manual check: dictation and ⌘C-cancels-recording still work in the app
- [x] `swift test` passes

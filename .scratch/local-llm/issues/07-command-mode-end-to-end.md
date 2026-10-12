# 07: Command Mode end to end (Shift + push-to-talk)

**What to build:** Holding Shift at any point while the push-to-talk key is down switches the session to Command Mode (sticky until release). The HUD shows the Command Mode look. On release, the spoken instruction, the selection, ~300 characters of context on each side and the app category go to a FlowCore Command Mode entry point. The result replaces the selection, or is inserted at the cursor when nothing is selected. A rejected result or no model shows a HUD message and pastes nothing. Runs on the models available now (Apple's model); Qwen 4B is added in ticket 08. See the spec, sections "Hotkey state machine seam" and "Command Mode flow".

**Blocked by:** 01 (TextModel seam + FlowCore formatting module), 02 (Push-to-talk state machine)

**Status:** ready-for-agent

- [x] State machine: Shift while held gives command mode; Shift already held at press gives command mode; Shift released before key release keeps command mode; any other modifier or keyDown still interrupts; emits a mode-changed event
- [x] State machine tests cover each rule above
- [x] HUD switches to a distinct Command Mode look as soon as Shift is detected
- [x] FlowCore Command Mode entry point: owns the prompt (instruction + selection + context + category; output in the selection's language unless a translation is asked), guards (non-empty, wrapping stripped, length cap), and cascade; returns text or a typed failure
- [x] Command Mode tests with fake `TextModel`s: replacement vs insertion, cascade, rejected output, no model available
- [ ] With a selection, the result replaces it via the existing paster; ⌘Z undoes it in standard apps
- [ ] Without a selection, the result is inserted at the cursor with the dictation leading-space logic
- [x] Rejected output or no model: HUD message, nothing pasted, instruction never pasted as text
- [ ] Manual check: "make this more formal" on a selection in Mail; "write a short email moving the meeting to Thursday" with no selection

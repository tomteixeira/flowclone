# 01: TextModel seam + FlowCore formatting module (prefactor)

**What to build:** Move the formatting logic (prompt, skip heuristic, output guards, fallback) out of the app-side `Formatter` into a FlowCore module that talks to language models only through a new `TextModel` protocol. Apple's foundation model becomes a thin `TextModel` adapter in the app target. Dictation in the app behaves exactly as before. See the spec, section "TextModel seam (FlowCore)".

**Blocked by:** None (can start immediately)

**Status:** done (manual app check pending)

- [x] `TextModel` protocol in FlowCore: instructions + prompt + generation options in, text out (async); can report unavailable; can throw
- [x] FlowCore formatting entry point takes raw transcript, language, app category, before-cursor text, and an ordered list of candidate models, and returns the text to paste
- [x] Cascade: unavailable or throwing model falls through to the next one; no model left gives the raw transcript
- [x] Guards rejecting an output (answered question, expansion, empty, wrapping) fall through the same way
- [x] Engine setting `off` never calls a model; `apple` uses only the Apple adapter
- [x] Apple Foundation Models adapter contains no prompt or guard logic
- [ ] App and `--transcribe` call the FlowCore module; pasted output is unchanged for the same inputs (code path wired and prompt/options moved verbatim; manual check in the app and with `--transcribe` still to do)
- [x] XCTest coverage with fake `TextModel`s for cascade, guards, skip heuristic and `off`, in the style of `TextHeuristicsTests`
- [x] `swift test` passes

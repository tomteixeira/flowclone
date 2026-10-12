# 03: Evaluation harness + FR/EN corpus, Apple baseline

**What to build:** A CLI mode, next to `--transcribe`, that runs a formatting corpus (JSONL) through the FlowCore formatting module with a chosen engine, writes an output JSONL, and prints a summary. Ship a hand-written corpus of about 80 French/English cases and record a first baseline on Apple's model. See the spec, section "Evaluation harness".

**Blocked by:** 01 (TextModel seam + FlowCore formatting module)

**Status:** resolved

- [x] Corpus case shape: raw text, language, app category, before-cursor text, optional `expect` fields (must contain / must not contain / ending punctuation)
- [x] About 80 cases, balanced FR/EN, covering fillers, self-corrections, questions, command-like dictations (model must not answer), emails, chat, code/terminal, proper nouns, very short inputs
- [x] Output JSONL per case: input, output, model, latency, guard result, rule-check failures
- [x] Summary: p50/p95 latency, model load time, peak memory, guard-pass rate, rule-check failure count
- [x] Rule checks: guards passed, language kept, no answered question, expectations met
- [x] Engine selectable from the command line (Apple for now; open to any `TextModel`)
- [x] Baseline run on Apple's model committed or documented next to the corpus
- [x] Usage documented in the README

## Comments

- CLI: `FlowClone --eval <corpus.jsonl> [--engine apple] [--out <file.jsonl>]` (`Sources/FlowClone/EvalCommand.swift`). Pure logic in `FlowCore/Evaluation.swift` (`EvalCase` with a `task` field for Command Mode cases later, `Evaluation.run`, `EvalRules`, `EvalSummary`).
- Baseline run for real on Apple's model (M5, macOS 26.2): `eval/baselines/apple.jsonl` + `apple.summary.txt`. p50 ~640 ms / p95 ~1.2 s (noisy: p50 500-830 ms across runs), guard pass 92%, 22 rule-check failures in 17 of 80 cases.
- French examples added to the formatting prompt (ticket 01 carry-over), plus French fillers in the filler list and an email style that no longer invites invented sign-offs. Validated with the corpus: 26 failures in 19 cases before, 22 in 17 after. A variant listing self-correction keywords was dropped: it made the model keep "mars" in "mars non pardon d'avril".
- `stripModelWrapping` now also strips a tag wrapping the whole output (`<after_cursor>...</after_cursor>`), seen on the corpus.
- Not fixed, noted for ticket 05: the model echoes the before-cursor text into its output (6 cases), which the guards reject.

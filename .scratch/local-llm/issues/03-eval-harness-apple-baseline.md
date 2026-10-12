# 03: Evaluation harness + FR/EN corpus, Apple baseline

**What to build:** A CLI mode, next to `--transcribe`, that runs a formatting corpus (JSONL) through the FlowCore formatting module with a chosen engine, writes an output JSONL, and prints a summary. Ship a hand-written corpus of about 80 French/English cases and record a first baseline on Apple's model. See the spec, section "Evaluation harness".

**Blocked by:** 01 (TextModel seam + FlowCore formatting module)

**Status:** ready-for-agent

- [ ] Corpus case shape: raw text, language, app category, before-cursor text, optional `expect` fields (must contain / must not contain / ending punctuation)
- [ ] About 80 cases, balanced FR/EN, covering fillers, self-corrections, questions, command-like dictations (model must not answer), emails, chat, code/terminal, proper nouns, very short inputs
- [ ] Output JSONL per case: input, output, model, latency, guard result, rule-check failures
- [ ] Summary: p50/p95 latency, model load time, peak memory, guard-pass rate, rule-check failure count
- [ ] Rule checks: guards passed, language kept, no answered question, expectations met
- [ ] Engine selectable from the command line (Apple for now; open to any `TextModel`)
- [ ] Baseline run on Apple's model committed or documented next to the corpus
- [ ] Usage documented in the README

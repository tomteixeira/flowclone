# 05: Compare Qwen3 1.7B vs Apple and set the default order

**What to build:** Run the eval harness on Apple's model and on Qwen3 1.7B over the same corpus, judge the outputs qualitatively in a Claude Code session, and set the Auto engine's default order according to the spec's rule: Qwen first only if it matches or beats Apple on quality within the latency budget (< 400 ms per sentence, < 1.2 s per 30 s paragraph).

**Blocked by:** 03 (Evaluation harness), 04 (MLX adapter + Qwen3 1.7B)

**Status:** resolved

- [x] Both runs produced on the same corpus and machine (M5, 16 GB)
- [x] Qualitative judgement written up (per-category wins/losses, notable failures)
- [x] Decision recorded (an ADR is a good fit) and the default-order constant set accordingly
- [x] If Qwen loses: follow-up noted (prompt iteration, other models, LoRA)

## Comments

- Decision recorded in ADR 0001 (`docs/adr/0001-apple-first-in-auto-formatting.md`). Apple stays first in Auto. `FormattingEngine.autoOrder = [.apple, .local]` is unchanged and is already the spec's default. Qwen3 1.7B is ~2x faster (p50 280 vs 639 ms; Apple measured on a debug build). It loses on quality: 45 failures in 24 cases vs 22 in 17. It keeps the wrong side of self-corrections, drops "?" on questions and keeps fillers. It only wins on command-like dictations.
- Follow-ups: prompt iteration (in the ADR), other models (ticket 11), LoRA fine-tuning (in the ADR).

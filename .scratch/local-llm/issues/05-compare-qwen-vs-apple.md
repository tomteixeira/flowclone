# 05: Compare Qwen3 1.7B vs Apple and set the default order

**What to build:** Run the eval harness on Apple's model and on Qwen3 1.7B over the same corpus, judge the outputs qualitatively in a Claude Code session, and set the Auto engine's default order according to the spec's rule: Qwen first only if it matches or beats Apple on quality within the latency budget (< 400 ms per sentence, < 1.2 s per 30 s paragraph).

**Blocked by:** 03 (Evaluation harness), 04 (MLX adapter + Qwen3 1.7B)

**Status:** ready-for-human

- [ ] Both runs produced on the same corpus and machine (M5, 16 GB)
- [ ] Qualitative judgement written up (per-category wins/losses, notable failures)
- [ ] Decision recorded (an ADR is a good fit) and the default-order constant set accordingly
- [ ] If Qwen loses: follow-up noted (prompt iteration, other models, LoRA)

# 11: Try other local models for formatting

**What to build:** Run the formatting eval on a few other 4-bit `mlx-community` models, using the same corpus, machine and prompt as the ticket-05 baselines. The goal is to find a local model that matches or beats Apple's model on quality within the latency budget. No app code changes, except what a model needs to load through `MLXTextModel` and the eval harness (for example, chat-template flags). See ADR 0001 (`docs/adr/0001-apple-first-in-auto-formatting.md`) for the baselines and the failure modes to watch.

Candidates (repos checked on the HF API on 2026-10-12; each `model_type` is registered in the pinned `mlx-swift-lm`):

- `mlx-community/Qwen3-4B-Instruct-2507-4bit` (qwen3, non-thinking, ~2.3 GB)
- `mlx-community/Qwen3.5-2B-4bit` (qwen3_5, ~1.7 GB)
- `mlx-community/gemma-4-e2b-it-4bit` (gemma4, ~3.5 GB on disk)
- `mlx-community/Ministral-3-3B-Instruct-2512-4bit` (mistral3, ~2.8 GB)
- `mlx-community/LFM2.5-1.2B-Instruct-4bit` (lfm2, ~0.7 GB)
- `mlx-community/SmolLM3-3B-4bit` (smollm3, ~1.7 GB, reasoning mode must stay off)

Run: `.build/release/FlowClone --eval eval/formatting-corpus.jsonl --engine <org/name> --out eval/baselines/<short-name>.jsonl`

**Blocked by:** none

**Status:** ready-for-agent

- [ ] Each candidate loads through `MLXTextModel` with no reasoning/`<think>` content in the output (note any that need a template flag or don't load at all)
- [ ] Release-build run per candidate on the M5 16 GB; `eval/baselines/<short-name>.jsonl` + `.summary.txt` committed (p50/p95, load time, peak memory, guard pass rate, rule-check failures)
- [ ] Apple re-run on a release build, so the latency comparison is like for like
- [ ] Qualitative judgement per candidate against Apple, focused on the ADR 0001 failure modes: self-corrections (wrong side kept), "?" on questions with French spacing, fillers, before-cursor echo, meaning changes in chat
- [ ] Outcome recorded: a new ADR if a candidate earns the first place in Auto (flip `FormattingEngine.autoOrder`) or replaces Qwen3 1.7B as the fallback; otherwise, the best candidate to use as the LoRA base

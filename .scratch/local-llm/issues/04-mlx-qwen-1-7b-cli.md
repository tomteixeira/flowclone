# 04: MLX adapter + Qwen3 1.7B usable from the CLI

**What to build:** Add MLX Swift as a dependency and an MLX-backed `TextModel` adapter. Qwen3 1.7B (4-bit, `mlx-community`) downloads on first use into the FlowClone models directory and runs with thinking disabled and greedy decoding. `FLOWCLONE_LLM` forces a model id in `--transcribe` and in the eval harness. See the spec, section "Runtime and models".

**Blocked by:** 01 (TextModel seam + FlowCore formatting module)

**Status:** resolved

- [x] MLX Swift LLM package added; app still builds with `scripts/build-app.sh`
- [x] Confirm the `mlx-community` repo ids for Qwen3 1.7B and 4B (Instruct-2507 if present) and record them in the code as constants
- [x] MLX adapter implements `TextModel`; contains no prompt or guard logic
- [x] Qwen3 thinking is disabled (chat template flag or non-thinking variant); no `<think>` content ever reaches the output
- [x] Weights downloaded on first use to the FlowClone models directory; a second run doesn't re-download
- [x] `FLOWCLONE_LLM=<model id>` makes `--transcribe` and the eval harness use that MLX model
- [x] Demo: `--transcribe` on a French recording prints a cleaned transcript produced by Qwen 1.7B

## Comments
- Eval harness wired after merging ticket 03: `--eval … --engine <apple|qwen3-1.7b|qwen3-4b|org/name[@rev]>` goes through `TextModels.make(id:)`; without `--engine` it uses `FLOWCLONE_LLM`, then `apple`. MLX load time is `MLXTextModel.load(progress:)`, measured before the timed cases.
- Qwen3 1.7B baseline (release build, M5): `eval/baselines/qwen3-1.7b.jsonl` + `qwen3-1.7b.summary.txt`. p50 280 ms / p95 769 ms, load 3.1 s, peak memory 393 MB, guard pass 88%, 45 rule-check failures in 24 of 80 cases (Apple: 92%, 22 in 17). Main misses: questions lose their "?", self-corrections and fillers kept.

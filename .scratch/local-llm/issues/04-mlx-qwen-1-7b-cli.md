# 04: MLX adapter + Qwen3 1.7B usable from the CLI

**What to build:** Add MLX Swift as a dependency and an MLX-backed `TextModel` adapter. Qwen3 1.7B (4-bit, `mlx-community`) downloads on first use into the FlowClone models directory and runs with thinking disabled and greedy decoding. `FLOWCLONE_LLM` forces a model id in `--transcribe` and in the eval harness. See the spec, section "Runtime and models".

**Blocked by:** 01 (TextModel seam + FlowCore formatting module)

**Status:** ready-for-agent

- [ ] MLX Swift LLM package added; app still builds with `scripts/build-app.sh`
- [ ] Confirm the `mlx-community` repo ids for Qwen3 1.7B and 4B (Instruct-2507 if present) and record them in the code as constants
- [ ] MLX adapter implements `TextModel`; contains no prompt or guard logic
- [ ] Qwen3 thinking is disabled (chat template flag or non-thinking variant); no `<think>` content ever reaches the output
- [ ] Weights downloaded on first use to the FlowClone models directory; a second run doesn't re-download
- [ ] `FLOWCLONE_LLM=<model id>` makes `--transcribe` and the eval harness use that MLX model
- [ ] Demo: `--transcribe` on a French recording prints a cleaned transcript produced by Qwen 1.7B

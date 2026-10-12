# 0002: Qwen3 4B Instruct-2507 goes first in Auto formatting; Apple's model is the fallback

**Status:** accepted (2026-10-12). Supersedes [0001](0001-apple-first-in-auto-formatting.md).

## Context

ADR 0001 kept Apple's foundation model first in Auto because Qwen3 1.7B lost to it on quality. Ticket 11 ran eight other 4-bit `mlx-community` models through the same eval (80-case French/English corpus, same prompt, greedy decoding, release build, M5 16 GB), and re-ran Apple on a release build so latency compares like for like. Full table and per-model notes: `eval/baselines/COMPARISON.md`.

| | Apple foundation model (`apple-release`) | Qwen3 4B Instruct-2507 (`qwen3-4b-instruct-2507`) |
|---|---|---|
| Guard pass | 92% | **100%** |
| Rule failures (cases) | 22 (17) | **8 (8)** |
| Latency p50 / p95 | **509 / 756 ms** | 675 / 1279 ms (repeat: 685 / 1123) |
| Disk | system | 2.1 GB |

Qwen3 4B Instruct-2507 is the only candidate that beats Apple on quality. It fixes every Qwen3 1.7B failure category: questions keep their "?", short self-corrections keep the right side, fillers go, and command-like dictations are never obeyed. Its remaining failures are long dictations with a correction, one over-shortened French chat (fr-chat-2), and the before-cursor greeting echo (email-5) that every model, Apple included, makes. It is also already the pinned Command Mode model.

Neither model meets the spec's 400 ms sentence target. Qwen3 4B costs about 170 ms more than Apple at p50.

## Decision

- Auto formatting tries Qwen3 4B Instruct-2507 first, then Apple's model, then pastes the raw transcript: `FormattingEngine.autoOrder = [.local, .apple]`.
- `LocalModels.formatting` is the same spec as `LocalModels.commandMode`. The app downloads it once, keeps one residency and one `MLXTextModel` for both tasks. Qwen3 1.7B is no longer downloaded by the app. Its constant stays for the eval harness and `FLOWCLONE_LLM=qwen3-1.7b`.
- With local first, every push-to-talk key-down preloads the 4B, unless Formatting is Apple or Off.
- Residency rules (idle timeout, assumed load time) belong to the model. The wait budget for a load in progress belongs to the request (`LoadWait`, chosen by `LocalModelPlan.loadWait(for:appleAvailable:)`):
  - formatting waits up to 0.75 s, and only if the load should finish by then; otherwise Apple formats that dictation;
  - Command Mode waits up to 4 s, or until the load ends when no other model could take over.

## Consequences

- Quality first: Auto formats better than with Apple first (8 vs 22 rule failures) at ~170 ms more per dictation (p50 ~680 vs ~510 ms). We accept this trade-off.
- **Escape hatch:** users who find it too slow pick **Formatting → Apple** in the menu. That choice never loads or calls the local model for formatting (the cascade is Apple only, and key-down doesn't preload). Command Mode still uses Qwen3 4B when Shift is held. The menu labels say Auto is local Qwen first.
- About 2 GB of weights stay resident while the model is in use (released after 15 idle minutes), instead of ~1 GB for the 1.7B. First launch downloads 2.1 GB instead of 0.9 + 2.1 GB.
- The first dictation after a cold start often goes to Apple's model: the 4B load (~1–3 s, ~6 s assumed until measured) only fits the 0.75 s budget on longer holds. Later dictations find it loaded.
- Without Apple Intelligence, Auto still formats with Qwen3 4B.
- Follow-ups from ADR 0001 remain: the before-cursor echo looks like a prompt or post-processing fix, and Qwen3 4B Instruct-2507 is now the natural LoRA base. Gemma 4 E2B (p50 416 ms) is the candidate if latency becomes the priority, after a fix for its French "?" spacing.

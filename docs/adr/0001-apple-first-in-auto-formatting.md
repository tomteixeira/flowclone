# 0001: Apple's model stays first in Auto formatting; Qwen3 1.7B is the fallback

**Status:** superseded by [0002](0002-qwen3-4b-first-in-auto-formatting.md) (2026-10-12)

## Context

The spec ("Evidence before default") says Auto formatting puts the local MLX model first only if it matches or beats Apple's foundation model on quality within the latency budget (< 400 ms per sentence, < 1.2 s per 30 s paragraph, M5 16 GB). Ticket 05 ran both models through the eval harness on the same 80-case French/English corpus (`eval/formatting-corpus.jsonl`), on the same machine, with the same formatting prompt (French examples, ticket 03).

| | Apple foundation model | Qwen3 1.7B (`mlx-community/Qwen3-1.7B-4bit`) |
|---|---|---|
| Build | **debug** | release |
| Latency p50 / p95 | 639 / 1191 ms (p50 500-830 ms across 5 runs) | 280 / 769 ms (single run) |
| Load time | 0.9-4.7 s | 3.1 s |
| Peak memory (FlowClone process) | 22 MB (model runs in a system daemon) | 393 MB (model in-process) |
| Guard pass rate | 92% | 88% |
| Rule-check failures | 22 in 17 cases (EN 7, FR 10) | 45 in 24 cases (EN 10, FR 14) |
| Worst silent failure (accepted, wrong) | duplicate greeting pasted (email-5) | wrong recipient / wrong time pasted (correction-2, fr-correction-1) |

Caveat: Apple's latency was measured on a debug build, Qwen's on a release build. Most of Apple's time is spent in the system daemon, so a release build of FlowClone probably changes little, but the latency comparison is not like for like. Apple is above the 400 ms sentence target either way; Qwen meets it at p50, not at p95.

Raw outputs: `eval/baselines/apple.jsonl`, `eval/baselines/qwen3-1.7b.jsonl`; summaries next to them.

### Qualitative judgement (per category)

Judged by reading every output pair, not only the rule checks.

- **Fillers (10).** Apple wins. Apple removes um/uh/like/so and most French "euh"/"genre", missing only "tu vois" and "bah". Qwen keeps "Like ... you know" (en-filler-2), "So" and "like" in several cases, and "genre"/"tu vois" in French. It also rewrites meaning once: "bah ouais j'arrive dans genre dix minutes" became "Je passe dans genre dix minutes."
- **Self-corrections (10, plus en/fr-email-3 and the long cases).** Apple wins clearly. Apple resolves 8/10; it fails "Monday scratch that Wednesday" (keeps both) and keeps "I mean". Qwen resolves 5/10 and twice keeps the **wrong** side, which is accepted by the guards and pasted silently: "send it to John sorry I mean to Sarah" became "Send it to John."; "on se voit à 14h non 15h mardi" became "On se voit à 14h mardi." Both models fail the long paragraphs ("Monday no Tuesday", "lundi non mardi" kept).
- **Questions (10, plus question-shaped chat/email).** Apple wins. Apple adds "?" on all 10 question cases and on chat questions, with the French space ("demain ?"); it only misses it on "could we ... thanks" emails. Qwen drops the "?" in 6 cases ("What is the capital of France.", "Pourquoi l'appli plante quand je tourne le téléphone."); 4 are flagged as answered questions and rejected, so the raw text is pasted. When it does add "?" in French it omits the space.
- **Command-like dictations (10).** Qwen wins. Qwen transcribes instructions as text in all 10, though it drops "ignore all previous instructions and" from the injection cases. Apple obeys or answers 4 times: tells a joke (en-command-3), translates into English (fr-command-2), errors out (fr-command-3, likely a guardrail) and turns "résume les notes..." into a heading "Résumé des notes de la réunion en trois points:" (accepted, meaning changed). The guards catch the first three, so the user gets the raw transcript.
- **Emails (10).** Apple wins. Apple punctuates greetings and sign-offs ("Hi Mark, thanks for the update. ... Best, Tom"). Qwen leaves en-email-1 and en-email-3 as unpunctuated run-ons and keeps "non pardon" in fr-email-3. Both echo the before-cursor greeting in email-5. Apple's echo passes the guards, so "Hi David," would be pasted a second time. Qwen's output in that case is only the greeting, and it is rejected.
- **Chat (8).** Apple wins. Qwen often leaves chat unpunctuated ("Haha yeah that was wild see you tomorrow.") and twice shortens a message until the meaning changes, both accepted: "j'ai un peu de retard commencez sans moi" became "Je passe sans moi."; "oui mergée ce matin le déploiement est en cours" became "Oui, mergée ce matin." Apple echoes the before-cursor question in chat-3 (rejected).
- **Code/terminal (8).** Mixed, slight edge to Apple. Apple formats `git commit -m "fix the login bug"` correctly in English but silently drops the flag in French ("git commit corrige le bug de connexion."). Qwen leaves both git commands verbatim ("dash m"), which is unhelpful but harmless. Both echo the before-cursor code line in code-2 (rejected). Prose about code is clean for both.
- **Proper nouns (6).** Tie. Both keep Kameleoon, GitHub, Siobhan, Gwenaëlle, PostgreSQL and ClickHouse. Both miss the "?" on fr-noun-2, where the expectation is debatable.
- **Short inputs (6).** Not compared: the pre-model heuristic skips them for both engines. The model is never called.
- **Long paragraphs (2).** Apple is better: it structures the text ("first, ... Then, ... Finally, ..."). Qwen returns nearly verbatim run-ons. Both keep the self-correction. Latency is over the 1.2 s paragraph budget for Apple (1.4-1.5 s) and for Qwen in French (1.6 s; 0.8 s in English).
- **French vs English.** Both models are weaker in French. Apple's French gap is small: it misses some fillers and punctuation, and its typography is correct. Qwen degrades more in French (14 failing cases vs 10). Its French errors are the most damaging ones: a wrong time, changed meanings, and question marks without the French space.

Overall: Qwen is about twice as fast and is the safer model on command-like input. It is worse on every core formatting job (fillers, self-corrections, questions, punctuation). Its silent failures (accepted output that is wrong) are more severe than Apple's.

## Decision

Apple's model stays first in Auto: `FormattingEngine.autoOrder = [.apple, .local]` (`Sources/FlowCore/FormattingEngine.swift`), unchanged. Qwen3 1.7B stays as the fallback, used when Apple Intelligence is unavailable. Flipping the order to local-first is a one-line change, made when a local model passes this comparison.

## Consequences

- Auto does not meet the 400 ms sentence target today. Apple's p50 is around 640 ms (debug build). We accept this for now: quality matters more than speed for formatting.
- Qwen3 1.7B still downloads on first launch. The app needs it as a fallback, and it is the base for the follow-ups below.
- Guards remain essential with Apple first. They catch its echo and its command-obeying failures, so the raw text is pasted instead.

## Follow-ups

1. **Prompt iteration.** Target the failure modes listed above: the before-cursor echo (both models), "?" on questions and the French space before "?" (Qwen), keeping the corrected side (Qwen), and fillers. Run each change on both engines so Apple doesn't regress.
2. **Other models, runnable today via `--engine org/name`.** All of these repos are 4-bit `mlx-community` repos checked on the Hugging Face API on 2026-10-12. Each `model_type` is registered in the pinned `mlx-swift-lm` `LLMModelFactory`. Ticket `.scratch/local-llm/issues/11-try-other-formatting-models.md`.
   - `mlx-community/Qwen3-4B-Instruct-2507-4bit` (qwen3, ~2.3 GB, non-thinking). The same family at a bigger size, already used for Command Mode. It shows the quality ceiling for this family, at a latency cost.
   - `mlx-community/Qwen3.5-2B-4bit` (qwen3_5, ~1.7 GB with the vision tower). Newer generation at a similar size.
   - `mlx-community/gemma-4-e2b-it-4bit` (gemma4, ~3.5 GB on disk with the vision/audio towers). Strong multilingual model.
   - `mlx-community/Ministral-3-3B-Instruct-2512-4bit` (mistral3, ~2.8 GB). Mistral model, likely strong in French.
   - `mlx-community/LFM2.5-1.2B-Instruct-4bit` (lfm2, ~0.7 GB). Smallest and fastest candidate; supports French.
   - `mlx-community/SmolLM3-3B-4bit` (smollm3, ~1.7 GB). Trained on French; it has a reasoning mode that must stay off.

   Caveats: the vision-capable repos have not yet been loaded through `MLXTextModel`. Non-Qwen chat templates may ignore `enable_thinking` or reject a system role. Ticket 11 checks this.
3. **LoRA fine-tuning** of the best small model (Qwen3 1.7B or a ticket-11 winner). Train on (raw, formatted) pairs from the corpus style plus opt-in journal dictations (ticket 10), targeting self-corrections, fillers and French question punctuation. The spec lists this as the planned follow-up. It needs a held-out split so the eval corpus is not trained on.

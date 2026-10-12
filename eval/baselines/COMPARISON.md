# Formatting models compared

All runs: `eval/formatting-corpus.jsonl` (80 cases, 74 scored, 6 skipped), same formatting prompt, greedy
decoding, release build, Apple M5 16 GB, macOS 26.2, 2026-10-12. MLX models are the 4-bit
`mlx-community` conversions, run with `enable_thinking: false`; no adapter change was needed. Each model has
its records in `<slug>.jsonl` and its numbers, notes and failing cases in `<slug>.summary.txt`.

| Model (slug) | Disk | Guard pass | Rule failures (cases) | p50 / p95 ms | Load ms | Peak mem |
|---|---|---|---|---|---|---|
| Apple foundation model (`apple-release`) | system | 92% | 22 (17) | 509 / 756 | 1062 | 26 MB¹ |
| Qwen3 1.7B (`qwen3-1.7b`) | 0.9 GB | 88% | 45 (24) | 280 / 769 | 3062 | 393 MB |
| **Qwen3 4B Instruct-2507** (`qwen3-4b-instruct-2507`) | 2.1 GB | **100%** | **8 (8)** | 675 / 1279 | 912 | 1946 MB |
| Gemma 4 E2B it (`gemma-4-e2b`) | 3.3 GB² | 97% | 11 (9) | 416 / 683 | 2246 | 1975 MB |
| Qwen3.5 2B (`qwen3.5-2b`) | 1.6 GB | 96% | 21 (13) | 350 / 518 | 3189 | 830 MB |
| Ministral 3 3B Instruct 2512 (`ministral-3-3b`) | 2.6 GB | 91% | 21 (16) | 520 / 836 | 1026 | 2708 MB |
| Llama 3.2 3B Instruct (`llama-3.2-3b`) | 1.7 GB | 89% | 23 (19) | 517 / 1191 | 1177 | 1782 MB |
| SmolLM3 3B (`smollm3-3b`) | 1.6 GB | 91% | 30 (23) | 536 / 805 | 918 | 1852 MB |
| LFM2.5 1.2B Instruct (`lfm2.5-1.2b`) | 0.6 GB | 80% | 69 (37) | 204 / 373 | 468 | 716 MB |

¹ Apple's model runs in a system daemon; only FlowClone's own memory is counted.
² Includes vision and audio weights the text model never loads.

How to read the numbers:

- **Latency** is per case, single run. A repeat gave Qwen3 4B p50 685 / p95 1123 ms and Qwen3 1.7B
  p50 328 / p95 976 ms, so differences under ~50 ms (p50) or ~200 ms (p95) are noise. No other eval or MLX
  process ran during any run (checked before and after each); other agents' `swift build` jobs may have
  shared the CPU, so absolute latency may be slightly high, roughly equally for all models.
- **Load** and **peak memory** were measured after a warm-up run that downloaded the weights. They depend on
  the OS page cache and vary 2–3× run to run (Qwen3 4B repeat: 2863 ms, 735 MB). Peak memory is `ru_maxrss`,
  which undercounts mmapped weights. The disk size is the better guide to resident memory.
- The Qwen3 1.7B row is the earlier release-build baseline (`qwen3-1.7b.summary.txt`). Apple on the
  release build failed exactly the same 17 cases as on the debug build (`apple.summary.txt`).

## Failure categories

These are the failure categories that sank Qwen3 1.7B, judged by reading every failing output, plus the
passing chat, question and correction outputs of the top four.

| Model | Questions keep "?" | Self-corrections | Fillers | Before-cursor echo | Chat meaning | Obeys dictation |
|---|---|---|---|---|---|---|
| Apple | good | fails in long dictations, en-correction-4/5 | keeps some ("tu vois", "bah") | email-5, chat-3, code-2 | good | rejected/refused 3 |
| Qwen3 1.7B | **poor** (8) | **poor**, keeps both sides | **poor** | email-5, code-2 | **poor** (fr-chat-2/3) | 4 answered |
| Qwen3 4B Instruct-2507 | good | good, except long dictations | good | email-5 only | fr-chat-2 over-shortened | never |
| Gemma 4 E2B | good, but "demain?" (no French space) | en-correction-4 **drops** "Wednesday"; long dictations keep both | good | email-5, code-2 | good | never |
| Qwen3.5 2B | 3 lost | **poor**, keeps both sides or drops the fix | keeps "uh"/"um" in long text | email-5 | fr-chat-2 meaning changed | translates fr-command-2 |
| Ministral 3 3B | "Tu peux…?" turned into imperatives | long dictation keeps the wrong day | good | email-5 | over-shortened | translates, writes code, reformats as lists |
| Llama 3.2 3B | 3 lost | loses the fix (en-email-3 keeps "March") | keeps "tu vois" | email-5, writes code for code-2 | **poor** in French | tells the joke (EN and FR) |
| SmolLM3 3B | 3 lost | keeps both sides | **poor** in French | email-5, chat-3 | leaks `<dictation>` tags | tells the joke |
| LFM2.5 1.2B | **poor** | **poor** | **poor** | email-5 | **poor** | answers questions, echoes the prompt |

Per model:

- **Qwen3 4B Instruct-2507**: fixes every Qwen3 1.7B failure category. Questions keep their "?", short
  self-corrections are resolved, fillers are removed, before-cursor text is echoed only in email-5 (every
  model does that), and command-like dictations are never obeyed. Remaining issues: long dictations ("Monday
  or Tuesday", "lundi, non mardi"), one over-shortened French chat (fr-chat-2 drops "j'ai un peu de retard"),
  "Git commit" capitalised. Cost: p50 ~680 ms, about 170 ms slower than Apple, and 2.1 GB on disk.
- **Gemma 4 E2B**: close second on scores and faster (p50 416 ms). Its French typography is wrong ("?"
  without the non-breaking space), and en-correction-4 drops the corrected value, which loses meaning.
  It is 3.3 GB on disk because the repo bundles vision and audio towers. A text-only conversion would
  need re-quantising ourselves.
- **Qwen3.5 2B**: fast (350 ms) and small, but makes the same mistakes as Qwen3 1.7B on corrections, and
  switches French tu→vous.
- **Ministral 3 3B**: rewrites rather than formats (translations, numbered lists, imperatives), and makes
  French grammar errors. Not suitable.
- **Llama 3.2 3B**, **SmolLM3 3B**: obey prompt-injection dictations, are weak in French, and SmolLM3 leaks
  the prompt's XML tags.
- **LFM2.5 1.2B**: often returns the raw text or a line of the system prompt. Unusable with this prompt.

The en/fr-email-5 failure (the model repeats the "Hi David," greeting that is already before the cursor) is
universal, Apple included. It looks like a prompt or post-processing fix (strip a leading copy of the
before-cursor text), not a model choice. fr-noun-2 and fr-correction-5 ("tu peux …") end with "." for every
model. They are arguably ambiguous between a request and a question.

## Recommendation

Qwen3 4B Instruct-2507 is the only local model that beats Apple on quality: 8 failures vs 22, no guard
rejections. It is also already pinned as the Command Mode model, so formatting and Command Mode could share one
resident 2.1 GB model. Its latency (p50 ~680 ms) is above Apple's (~510 ms) and well above the 400 ms target,
so it should be the default local formatter only where quality matters more than speed. Gemma 4 E2B is the
fallback if latency is the priority, but it needs a fix for the French "?" spacing and has to accept a 3.3 GB
download.

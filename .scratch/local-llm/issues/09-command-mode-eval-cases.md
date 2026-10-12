# 09: Command Mode cases in the eval harness

**What to build:** The eval harness accepts Command Mode cases (instruction, selection, before/after context, app category, expectations) and runs them through the FlowCore Command Mode entry point with any engine. Ship a starter FR/EN Command Mode corpus.

**Blocked by:** 03 (Evaluation harness), 07 (Command Mode end to end)

**Status:** ready-for-agent

- [ ] Command Mode case shape defined; harness detects or is told the case type
- [ ] Starter corpus (~30 cases, FR/EN): rewrite tone, translate, summarize, fix grammar, generate with no selection, reply using surrounding context
- [ ] Rule checks: non-empty, no wrapping, language kept unless translation asked, length sane
- [ ] Same output JSONL + summary format as formatting runs
- [ ] Runs against Apple's model and, once ticket 08 lands, Qwen 4B via `FLOWCLONE_LLM`

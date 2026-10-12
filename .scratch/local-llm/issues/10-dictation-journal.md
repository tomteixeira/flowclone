# 10: Dictation journal (opt-in)

**What to build:** A "Keep dictation journal" menu toggle (off by default) and a "Clear journal" item. When on, every formatting run and every Command Mode run appends one record to a local JSONL file in Application Support. Journal records can be turned into eval corpus cases. See the spec, section "Dictation journal".

**Blocked by:** 03 (Evaluation harness), 07 (Command Mode end to end)

**Status:** ready-for-agent

- [ ] Codable record type in FlowCore with a formatting variant (raw, formatted, language, app category, model, latency, 300 chars before cursor) and a Command Mode variant (instruction, selection, context, result, model, latency)
- [ ] Round-trip encode/decode tests; one record per line
- [ ] Nothing is written while the toggle is off
- [ ] "Clear journal" deletes the file
- [ ] Journal file (or a filtered subset) can be fed to the eval harness as a corpus
- [ ] Data never leaves the machine

# 10: Dictation journal (opt-in)

**What to build:** A "Keep dictation journal" menu toggle (off by default) and a "Clear journal" item. When on, every formatting run and every Command Mode run appends one record to a local JSONL file in Application Support. Journal records can be turned into eval corpus cases. See the spec, section "Dictation journal".

**Blocked by:** 03 (Evaluation harness), 07 (Command Mode end to end)

**Status:** resolved (branch ticket-10). "Nothing written while off" and "Clear journal" are enforced in AppController/JournalFile, checked by reading, not unit tested. Command Mode records convert to eval cases once ticket 09 adds the case type (`JournalRecord.evalCase`).

- [x] Codable record type in FlowCore with a formatting variant (raw, formatted, language, app category, model, latency, 300 chars before cursor) and a Command Mode variant (instruction, selection, context, result, model, latency)
- [x] Round-trip encode/decode tests; one record per line
- [x] Nothing is written while the toggle is off
- [x] "Clear journal" deletes the file
- [x] Journal file (or a filtered subset) can be fed to the eval harness as a corpus
- [x] Data never leaves the machine

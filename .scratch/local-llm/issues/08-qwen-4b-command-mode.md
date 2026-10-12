# 08: Qwen3 4B for Command Mode

**What to build:** Qwen3 4B (4-bit, Instruct-2507 if available) downloads in the background once Qwen 1.7B is in place, loads as soon as Shift switches a session to Command Mode, sits first in the Command Mode cascade ahead of Apple's model, and unloads after inactivity like the 1.7B.

**Blocked by:** 06 (Auto engine in the app), 07 (Command Mode end to end)

**Status:** ready-for-agent

- [ ] Background download starts after the 1.7B is ready; progress visible; failures retry
- [ ] Command Mode cascade: Qwen 4B, then Apple, then HUD message
- [ ] Load starts on the mode-changed event (Shift detected), not on key-down; formatting sessions never load the 4B
- [ ] 4B released after ~15 minutes without use, independently of the 1.7B
- [ ] While the 4B is downloading, Command Mode keeps working through Apple's model
- [ ] Manual check with Apple Intelligence disabled: Command Mode works through Qwen 4B

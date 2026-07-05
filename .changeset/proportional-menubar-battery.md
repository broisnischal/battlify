---
"battlify": patch
---

Menu-bar battery icon now fills proportionally to the exact charge.

The status-item battery was drawn with SF Symbols, which only offer five fixed fills (0/25/50/75/100), so the level appeared to jump in big steps and looked unchanged for wide percentage ranges. It's now a custom-drawn battery whose inner fill width tracks the real percentage, while keeping the adaptive template look and the low/warm/charging colours.

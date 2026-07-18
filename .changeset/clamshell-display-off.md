---
"battlify": patch
---

Fix Always Active leaving the internal display and keyboard backlight on with the lid
closed. Keeping the Mac awake with the lid shut skips macOS's normal clamshell
display-off, and the previous one-shot display sleep didn't hold. Battlify now
re-issues a forced display sleep while the lid is shut and Always Active is holding —
so the panel and keyboard backlight go dark and stay dark — and it never runs when an
external display is attached, so a docked monitor is untouched.

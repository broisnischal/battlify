---
"battlify": patch
---

Always Active: turn off the display and keyboard backlight while the lid is closed.

When "Always Active" is holding the Mac awake and you close the lid, the daemon now forces the display to sleep (the keyboard backlight follows it) so background jobs keep running without the hidden panel and backlight draining power. It re-triggers each time the lid closes and resets when the lid opens or keep-awake stops holding.

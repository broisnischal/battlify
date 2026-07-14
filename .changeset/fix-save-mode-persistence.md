---
"battlify": patch
---

Fix save mode / charge settings resetting on their own.

- **Lid-close deep save** ("Super save on lid close") no longer re-applies a whole save mode on wake. It now restores only what it actually changed — Low Power Mode and the sleep/wake toggles — so your custom charge limit and heat settings survive a lid close/open cycle, and the mode can no longer silently reset to **Off** when it couldn't be read at sleep.
- **Switch mode by Wi-Fi network** no longer re-applies the mode that's already active (on launch or reconnect), which previously overwrote custom charge-limit/heat tweaks made within that mode.

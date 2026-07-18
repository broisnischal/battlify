---
"battlify": minor
---

Add **Keep Awake (Caffeine)** mode — a one-tap "never off, never sleeps" toggle.

A new tile in the menu's Quick Actions keeps the display from turning off and the
Mac from idle-sleeping, the same thing `caffeinate -d` does.

- Works on battery *and* wall power (unlike the AC-gated "Always Active" keep-awake).
- Needs no root and no helper daemon — it's a user-space `PreventUserIdleDisplaySleep`
  power assertion held by the app, so it works even before the helper is installed.
- Tap to hold indefinitely, or press-and-hold the tile for a timed session (30 min /
  1 / 2 / 5 hours) that auto-releases.
- Closing the lid still sleeps the Mac, and the assertion is released the instant
  Battlify quits — so it can never leave the Mac stuck awake.

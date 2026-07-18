---
"battlify": patch
---

Make the app relaunch reliably after an in-app update.

The post-update relaunch fired a single `open` and assumed it worked. It now
re-registers the swapped bundle, waits briefly for Launch Services to settle, then
relaunches with `open -n` and verifies the process actually came up — retrying a
few times (checking first, so it never spawns a duplicate) and falling back to a
launch by bundle id. If the app still isn't visible it logs a warning instead of
silently giving up.

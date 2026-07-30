---
"battlify": minor
---

The menu-bar glyph no longer animates while charging unless you ask it to.

The animation ticked twice a second, and every tick re-rendered the status item. A status-item relayout is expensive: measured on an M3 Pro, it cost about a tenth of a core continuously, for as long as the Mac was plugged in. Turning it off drops the app to 0% CPU at idle. That is not a trade a battery app should make on your behalf, so it is now a setting in General — off by default, with a static charging bolt instead. The brief flash when charging completes still runs; it lasts about three seconds rather than the whole charge.

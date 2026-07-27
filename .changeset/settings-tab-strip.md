---
"battlify": patch
---

Settings tabs no longer overflow the window.

Each tab claimed a fixed 76pt minimum plus padding, so a sixth tab pushed the row past the width of the window — the gaps went uneven and the last tab was clipped by the window edge. Tabs now share the bar equally, with margins at both ends, and the stray focus ring on the selected tab is gone.

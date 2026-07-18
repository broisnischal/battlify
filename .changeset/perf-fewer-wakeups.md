---
"battlify": patch
---

Performance: cut needless background wakeups. Live-watts polling now runs only while
the popover or Details window is open (instead of every 5 seconds for the app's whole
life), the daemon caches its `pmset` reads longer so periodic status polls stop forking
processes, and status refreshes only publish state that actually changed. Lower energy
impact with no change in behaviour.

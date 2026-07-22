---
"battlify": patch
---

Fix: the charge limit is now held through shutdown and restart. The helper's exit
cleanup used to re-enable charging on every SIGTERM (which launchd sends on
shutdown/restart), clearing the SMC charge inhibit. Because that inhibit persists
while the Mac is powered off but plugged in, the battery would then charge past
the limit — all the way to full — while the Mac was off. The daemon now leaves the
inhibit in place on exit whenever limiting is enabled, and only re-enables charging
when limiting is off. Uninstall re-enables charging after unloading the daemon.

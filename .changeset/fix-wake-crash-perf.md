---
"battlify": patch
---

Fix crash on lid reopen (added the required `NSBluetoothAlwaysUsageDescription`
so macOS no longer kills the app for touching Bluetooth without a usage string),
and big efficiency wins: process polling now runs only while the Details window is
open (no more `ps` every 5s in the background), and the battery/charge/lid pollers
were slowed (30s/30s/15s) since IOKit notifications already cover instant changes.
Also start the menu near its real height to reduce first-open flicker.

---
"battlify": patch
---

Notifications: register at launch, cleaner content, no emojis.

When notifications are enabled, the app now registers with the system at launch (via a shared authorization path) instead of waiting for an unpredictable state change, so it shows up in System Settings › Notifications and can deliver. Alerts are grouped under one thread and a same-kind alert is cleared (pending and delivered) before re-posting so they don't stack. Removed the emoji from the test-notification message; the charge alerts (limit, heat, low, full) stay plain text.

---
"battlify": patch
---

Fix the helper installer failing intermittently on reinstall/auto-update.

The install scripts unloaded the LaunchDaemon (`launchctl bootout`) and immediately
reloaded it (`launchctl bootstrap`). `bootout` is asynchronous, so bootstrapping
before the old job finished tearing down races and fails with `Bootstrap failed: 5:
Input/output error` — and because the scripts run under `set -e`, that aborted the
install and made the app report "Install cancelled or failed." This bit the common
path now that the app auto-reinstalls the helper whenever it's out of date.

- Wait for the old daemon instance to fully unload before bootstrapping, then retry
  bootstrap while the label frees up (and treat an already-loaded service as
  success, kickstarting it onto the new binary).
- `launchctl enable` the service before bootstrap, so a service left disabled by a
  prior failed install can still load.
- Strip the quarantine flag from the installed helper binary, so the (not-yet-
  notarized) daemon isn't killed by Gatekeeper right after install.

Applies to both the app-bundled installer and `scripts/install-helper.sh`.

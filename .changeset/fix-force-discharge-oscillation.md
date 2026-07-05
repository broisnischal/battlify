---
"battlify": patch
---

Fix force-discharge ("Discharge to limit" / recharge range) not draining the battery.

Cutting the power adapter to run off the battery makes macOS report the power source as "Battery Power", so the daemon read itself as unplugged on the very next tick, restored the adapter, and oscillated the adapter on/off every ~10s — the battery barely drained and the charge indicators flickered.

- The daemon now gates discharge on **physical adapter presence** (the raw SMC `AC-W` key, which stays true through a force-discharge, falling back to IOKit's `ExternalConnected`) instead of the providing-source flag. Discharge now runs continuously until it reaches the limit (or the cable is genuinely unplugged).
- Same fix applied to the MagSafe status LED (no longer flips to "Auto" mid-discharge), the prevent-idle-sleep assertion (no longer drops and lets the Mac sleep before draining finishes), and keep-awake.
- Bumps the helper build version so an already-installed daemon auto-updates.

---
"battlify": minor
---

Charge Power control, richer battery history, live charging watts, plus safety and performance fixes.

- **Charge Power** slider (0–100%) that gently duty-cycles charging in ~2-minute phases so you can trade charge speed for lower average power into the battery.
- **History**: new Charging Sessions, On Battery, Daily Summary, and Time at High Charge sections, plus Clear controls (chart / lid sessions / everything).
- **Live charging watts** in the menu-bar popover and an adapter → battery/Mac power split in Settings.
- New installs default the MagSafe LED to **Status**.
- **Fixes**: History now refreshes every time it opens; schedule-editor UI alignment and clearer day selector.
- **Performance/safety pass**: cached SMC/pmset/history reads, a safe (DispatchSource) shutdown handler, and a settings-write race fix.
- The app now **auto-updates its root helper** when it's older than the app ships (one admin prompt), so daemon fixes apply without a manual reinstall.

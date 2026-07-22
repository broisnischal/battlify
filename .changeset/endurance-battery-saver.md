---
"battlify": minor
---

Add **Endurance** — a battery-saver mode that targets ~25% less drain by layering the
biggest real power levers and restoring everything when turned off:

- Caps screen brightness (the single largest lever) via DisplayServices — works on
  Apple Silicon and Intel across macOS 12–15.
- Turns on macOS Low Power Mode.
- Trims battery-wasteful background wake (Power Nap / wake-on-network / TCP keep-alive)
  and turns Bluetooth off.
- Prior brightness, Low Power Mode, toggles and Bluetooth are snapshotted on activation
  and restored on exit.

Activation: a toggle in the menu and in Settings → Sleep & Power, plus optional
auto-on-battery (on by default) that activates when you unplug and deactivates when you
plug back in. The brightness cap is adjustable (default 40%).

**Measured drain meter** proves the effect: it shows live discharge watts and rolling
averages for normal vs. saver mode, and the measured % reduction — so you can confirm the
savings rather than trust an estimate (the exact figure is workload-dependent).

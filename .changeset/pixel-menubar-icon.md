---
"battlify": minor
---

Animated menu-bar battery icons.

- New "Pixel" icon style: a chunky 8-bit battery with notched corners. While
  charging, its fill sweeps from the current level up to full, one column at a
  time — like a classic handheld.
- Every other style's charging bolt now gently pulses while charging.
- When charging completes — the battery reaches 100% or lands at your charge
  limit — the icon flashes green a few times (or blinks monochrome when icon
  coloring is off), then settles.
- Micro-details: animations respect the system Reduce Motion setting, never run
  while discharging (a battery saver shouldn't spend cycles on battery), and the
  driving timer only exists while an animation is actually visible.

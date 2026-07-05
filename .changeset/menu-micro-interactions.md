---
"battlify": patch
---

Subtle animations and micro-interactions in the menu popover and Settings.

The charge bar now fills with a spring and the limit marker slides when values change; the big percentage rolls with a numeric-text transition; the bar gains a gentle breathing glow while charging; quick-action buttons have press + hover feedback; and the battery-style tiles lift on hover with a spring selection. All motion lives in views that only render while open (popover / Settings), so idle CPU stays at ~0% and the always-visible menu-bar icon is never animated — no background drain on a battery app.

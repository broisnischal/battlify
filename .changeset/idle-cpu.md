---
"battlify": patch
---

Cut the menu-bar app's idle CPU by roughly 17× (0.73% → 0.04% on an idle Mac).

The status item re-lays out on every published change, so republishing values that hadn't actually moved was costing continuous SwiftUI layout work in the background. The battery poll was the main offender: the temperature sensor jitters by hundredths of a degree, so every poll looked like a change. It now rounds to the precision actually displayed and publishes only real changes, skips reading live wattage entirely when no window is showing it, and does two follow-up reads per power event instead of four. The lid/display poll and the automation rule engine got the same treatment.

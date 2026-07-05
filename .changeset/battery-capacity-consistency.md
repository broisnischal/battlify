---
"battlify": patch
---

Battery capacity mAh now matches the health percentage.

The Details view derived "Maximum capacity" (%) from `NominalChargeCapacity` (matching macOS System Settings) but printed the "Capacity" mAh from `AppleRawMaxCapacity`, so the two disagreed — e.g. 5133/6249 mAh (82%) shown right beside a Health of 85%. Both now use the same figure, so the mAh ratio equals the percentage and matches macOS. Verified every displayed value (charge %, charging/plugged state, time remaining, cycles, temperature, health, capacity, and watts) against `pmset`, `ioreg`, and `system_profiler`.

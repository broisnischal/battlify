---
"battlify": minor
---

The helper stops working while your Mac sleeps.

It used to run its enforcement loop every 10 seconds regardless. With the lid shut on battery the only moment that loop can run is inside one of the maintenance wakes macOS schedules roughly hourly — and everything it did there (reading its config off disk, walking IOKit for the battery, probing the SMC) was pure cost, holding the chip awake in exactly the window that should end as fast as possible. Measured dark wakes ran 6–45 seconds, so a 10-second loop fired three or four times inside one.

There was also nothing for it to decide: the charge limit and the heat cap only act while current is flowing in. So it now drops to a 60-second loop once the lid is closed on battery, which leaves a typical maintenance wake seeing at most one pass. Measured cost after the change: 0.03% CPU.

Anything that genuinely has to react with the lid shut keeps the fast loop — Always Active's task gating, a discharge run, a schedule boundary, a ready-by top-up, a calibration, or a pause that has to expire on time.

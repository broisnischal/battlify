---
"battlify": minor
---

Keep-awake improvements and charging-correctness fixes:

- **Process picker**: pick the apps/processes that keep the Mac awake from a
  searchable list of what's currently running, instead of typing command names by
  hand ("Choose…" next to the process field). Selections are added to the list.
- **Sleep when the task finishes**: optionally put the Mac to sleep automatically
  once the monitored task stops (debounced ~30s so a gap between a build's
  sub-processes doesn't sleep mid-job), so an overnight build/download finishes and
  then the Mac sleeps.
- **Fix (Charge Power)**: with charge power below 100%, the duty-cycle rest phase was
  misread as "holding at the limit", so the battery drained to the bottom of the
  recharge band and never cycled back up. Hysteresis is now tracked explicitly and
  independent of the duty cycle.
- **Fix (heat)**: a failed battery-temperature read no longer silently disables the
  thermal cap; if the sensor has worked before, charging pauses as a precaution.
- **Fix (legacy SMC)**: charge state now reads both CH0B and CH0C, so a partial write
  that leaves one key allowing charge is retried instead of overshooting the limit.

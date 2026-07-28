---
"battlify": minor
---

New **Deep sleep** setting (Sleep & Power) for Macs that stay closed for days.

macOS normally keeps memory powered while the Mac sleeps so it wakes the instant you open the lid, writing a disk image only as a safety net. Deep sleep powers memory down and restores it from disk instead, which saves the small trickle that keeping memory alive costs over a long sleep. The trade is the wake: opening the lid takes several seconds while memory is read back, instead of being instant — so it's off by default and stays off when you upgrade.

On Apple silicon `hibernatemode` is the only lever that exists for this; the `standbydelay` knobs Intel Macs had aren't available, so there's nothing else to tune. Writing it needs root, so the root helper applies it — and reports back if pmset refuses.

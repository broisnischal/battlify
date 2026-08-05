---
"battlify": minor
---

**Fan control — and a fix for Macs this app left with their fans pinned at full speed.**

A machine running this app was found with both fans forced to 6,800 rpm on a cool chassis.
The cause: the fan-boost feature removed in 0.16 wrote `F0Md = 1` (forced) with a maximum
target, and forced mode **persists in the SMC** — it outlives the process that set it, and a
restart doesn't clear it, the same property the charge inhibit relies on. Deleting the code
that set it left nothing running that knew to undo it, so the fans stayed pinned
indefinitely, burning a couple of watts and adding heat and noise for nothing.

That also disproves the claim in the 0.16 notes that Apple silicon refuses SMC fan writes.
It doesn't: the write took, which is precisely why the machine stayed stuck.

So fans are supported properly now:

- **Monitoring.** Settings › Sleep & Power lists every fan with its live rpm and the range
  the hardware accepts, and marks any fan currently held.
- **Auto or Custom.** Auto hands the fans to macOS. Custom holds them at a percentage of
  each fan's own min…max range — a percentage rather than an rpm figure because the two fans
  in a machine needn't share a range, and "60%" means the same thing on both while
  "3,000 rpm" might be a crawl for one and near-max for the other.
- **It can't strand your fans.** The daemon hands them back when it stops, and on every tick
  it hands them back whenever the config says auto but the hardware says forced — which is
  what recovers a Mac left pinned by the removed feature, without the user needing to know
  any of this happened.
- **Heat always wins.** A manual speed below what the machine needs is the one way this can
  do harm, so above a temperature guard (85 °C by default) control returns to macOS whatever
  the setting says. 0% is each fan's own minimum, never off; the SMC won't accept less.

`HelperBuild` → 8, because the recovery lives in the daemon: a pinned Mac stays pinned until
a helper that knows to undo it is actually running.

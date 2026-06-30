---
"battlify": minor
---

Add **Discharge to limit** (hold-in-range) — when you plug in above your charge
limit, Battlify can run off the battery (force-discharge via the adapter SMC key,
CHIE on Tahoe) until it drops back to the limit, instead of sitting at a high
charge. The adapter is always re-enabled when not sailing down and on daemon exit,
so the Mac never gets stranded unable to charge.

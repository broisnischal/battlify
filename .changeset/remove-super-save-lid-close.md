---
"battlify": minor
---

Removed **Super Save when lid closed**.

The setting forced Low Power Mode on and turned off Power Nap, Wake on Network and
TCP Keep Alive every time the lid shut, then put them back on wake. On Apple silicon
a closed Mac already sleeps at essentially zero drain — measured lid-closed sessions
run 0–0.6 %/h with the plain settings — so the extra churn bought nothing while
briefly overriding power settings the user had chosen deliberately.

"When the lid closes" now holds only the three explicit toggles: turn off Wi-Fi,
turn off Bluetooth, and restore both on wake. Existing Wi-Fi/Bluetooth preferences
are untouched, and they are no longer greyed out.

The **On Battery** section in History is now labelled *awake and in use*, and
**While Lid Was Closed** is labelled *asleep*. The two sections share a row layout,
so an awake-usage row (a normal 8–19 %/h) read as sleep drain at a glance.

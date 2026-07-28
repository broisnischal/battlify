---
"battlify": minor
---

New **fan boost** (Sleep & Power → Fans): add airflow while real work is running.

Turn it on and Battlify spins the fans up whenever something is actually working — a long build, a render, agents grinding away — then hands them back to macOS the moment the work stops. It exists for the case the Always Active description warns about: heavy work with the lid shut runs hot, and a closed Mac has nowhere to put the heat.

You pick how hard to run them as a percentage of each fan's own range (the hint shows the RPM that works out to on your Mac), what counts as "working" (any process above a %CPU you choose), and optionally restrict the boost to when Always Active is holding the lid closed.

It can only ever ask for *more* airflow than macOS chose, never less — asking a fan to run slower than the firmware wants is how a Mac cooks, so there's no way to express that. The boost is clamped into each fan's reported minimum and maximum, forced mode is never engaged before a target RPM is written, and the fans go back to automatic when the work ends, when you switch it off, or when the helper exits — including on shutdown, since forced fan mode otherwise survives until reboot. If another fan utility already has your fans off automatic control, Battlify says so and leaves them alone.

---
"battlify": minor
---

- **Scheduled charge pause** — pause charging for 1h / 3h / 5h or until you resume;
  it auto-resumes when the timer runs out. Menu shows the remaining time.
- **MagSafe LED fix** — the LED now re-asserts every tick (green when charging is
  held/paused, orange while charging), so it actually changes when charging stops
  instead of being reset by macOS.
- **Reverted licensing to offline Ed25519** (removed Gumroad) — keys are verified
  locally against an embedded public key; `licensetool` mints/signs them.

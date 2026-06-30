# battlify

## 0.2.0

### Minor Changes

- **Super Save when lid closed** — closing the lid applies maximum battery saving
  (Low Power Mode, all sleep wake-ups off, Wi-Fi/Bluetooth off) and opening it
  restores your previous state, sleepwatcher-style.
- **Live lid / clamshell sensor** with a docked-mode battery-health warning.
- **Launch at Login** (via `SMAppService`).
- **In-app auto-update** — checks a public feed and offers a one-click download.

## 0.1.0

### Initial release

- Menu-bar battery monitoring (%, health, cycle count, temperature, capacity).
- **Charge limiting** via SMC (handles legacy `CH0B/CH0C` and Tahoe `CHTE`).
- **Heat-aware charging** — pause charging when the battery gets too warm.
- One-tap **Save Modes** (Off / Normal / Super Saver).
- **Sleep & Idle** controls (Power Nap, wake-on-network, TCP keep-alive).
- **Low Power Mode** toggle + top energy-using processes (suspend/resume).
- **Usage history** charts and a **Battery Health** tips card.
- Privileged root helper + Unix-socket control, with safe charge re-enable on exit.

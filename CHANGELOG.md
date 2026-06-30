# battlify

## 0.4.0

### Minor Changes

- **Discharge to limit (hold-in-range)** — when plugged in above the limit, run off
  battery (force-discharge via the adapter SMC key, CHIE on Tahoe) until it drops
  back to the limit. Adapter is always restored when not sailing down and on exit.
- **MagSafe LED status** — orange while charging, green when holding at the limit;
  handed back to macOS when disabled or on exit.
- **Lid-closed drain history** — records charge at lid close vs reopen and shows the
  drop and %/hour in Battery History.

### Patch Changes

- Fix crash on lid reopen (added `NSBluetoothAlwaysUsageDescription`) and big CPU
  cuts: process polling only while the Details window is open; slower background
  pollers; reliable Wi-Fi/Bluetooth restore-on-wake; faster post-wake refresh.
- Install docs: quarantine-flag fix, disable macOS Optimized Battery Charging.

## 0.3.1

### Patch Changes

- Optimization: drop the unused offline Ed25519 licensing code (`License.swift`)
  and the `licensetool` target now that licensing runs through Gumroad — smaller
  build, fewer targets, one clear licensing path.

## 0.3.0

### Minor Changes

- 38dfbbe: Monetization: use-based 30-day free trial (free days are only spent on days you
  actually use the app), $2.99 one-time purchase verified via Gumroad (Apple Pay at
  checkout), a source-available Battlify License, Changesets release management, and
  a polished README.

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

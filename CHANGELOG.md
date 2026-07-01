# battlify

## 0.8.2

### Patch Changes

- Fixed a crash on launch (the app opened then immediately quit) on macOS 26. A
  notification/observer callback used `MainActor.assumeIsolated`, which the macOS 26
  Swift runtime turns into a hard trap when the callback isn't on the main actor's
  executor. Those callbacks now hop to the main actor safely with `Task { @MainActor }`.

## 0.8.1

### Patch Changes

- **Fixed the self-updater failing to reopen / relaunch after an update.** The
  update script now runs fully detached from the app (so quitting to swap the
  bundle can't kill it mid-update), refreshes Launch Services so the new bundle
  isn't shadowed by a stale registration, clears quarantine, and retries the
  relaunch. It also logs each step for diagnosis.
- **Homebrew install** — `brew tap broisnischal/battlify-releases https://github.com/broisnischal/battlify-releases`
  then `brew install --cask battlify`. The cask clears the download quarantine on
  install so the app launches without a Gatekeeper warning, and it tracks each
  release automatically.

## 0.8.0

### Minor Changes

- **Notifications** — optional macOS alerts for charge events: charge limit
  reached, charging paused because the battery is warm, low battery, and fully
  charged. Enable them in Settings › General, with a "Send Test Notification"
  button to confirm they're working.
- **Recharge range** — an opt-in band under the charge limit: set a lower
  "Recharge at" level so the battery drains to it before topping back up to the
  limit, instead of sitting pinned at the top. Hidden unless you turn it on.
- **Red warning indicator** — the menu-bar icon and the in-app charge gauge now
  turn red when the battery is critically low or running warm.
- **Manage License from About** — a License row in Settings › About to activate
  or, once purchased, remove the license at any time.
- **Locked UI when the trial ends** — Details and History are disabled (alongside
  the charge controls) until the app is activated.
- **Snappier live updates** — plugging/unplugging the charger updates the menu
  immediately, re-reading a few times so IOKit's lagging charge flag settles.
- **Cleaner menu** — solid native popover background, a tidied footer, and the
  menu re-syncs its state every time it opens.

## 0.7.3

### Patch Changes

- Update the embedded license public key to the production storefront key so
  license keys issued after checkout activate correctly (previously valid keys
  failed with "This license key couldn't be verified").

## 0.7.2

### Patch Changes

- **In-app updates now install themselves** — clicking Update downloads the new
  version, replaces the app in place, and relaunches it automatically, instead of
  opening the download page for a manual drag-install. Falls back to the download
  page only if the app lives somewhere it can't update itself.

## 0.7.1

### Patch Changes

- **Fixed the menu popover on multi-monitor setups** — it now sizes to the display
  it actually opens on (the one under the cursor) instead of the screen holding
  keyboard focus, so it no longer gets clipped off the bottom or forced to scroll.
- **Consistent, native corner radii** — every card, banner, button, and tab now uses
  one harmonized radius scale with continuous (squircle) corners that match macOS's
  own windows and controls, instead of the previous mix of mismatched round corners.
- **Removed the Optimized Battery Charging prompt** — dropped the "Recommended Setup"
  card and the one-time menu nudge to streamline the UI.

## 0.7.0

### Minor Changes

- **Redesigned menu bar dropdown** — decluttered to the day-to-day essentials
  (battery status, Save Mode, charge limit, quick actions). The wordy per-toggle
  captions are gone; explanations now live where there's room for them.
- **New Settings window** — a dedicated window with **Charging**, **Sleep & Power**,
  and **General** tabs. Everything set-once (heat pause, MagSafe LED, sleep/wake
  behavior, menu-bar appearance, updates) moved here to keep the menu simple.
- **Helper management in Settings** — install, reinstall, or uninstall the root
  helper from the General tab, with live status (installed / not installed).
- **Optimized Battery Charging guidance** — a one-time nudge under the limit slider
  plus a Recommended Setup note in Settings, both with an "Open Battery Settings"
  button, so macOS's own charge management doesn't override your limit.
- **Slightly dim the display on battery** — a new toggle (Sleep & Power › On Battery)
  that lowers brightness a little when unplugged to stretch battery life.
- **Fixed Display Off** — turning the display off now waits briefly so the click
  that triggered it doesn't immediately wake the screen back up; it stays off until
  the next key press or trackpad tap.

## 0.6.1

### Patch Changes

- **Menu-bar display options** — hide the battery percentage (show just the icon)
  and turn off state coloring to keep the icon monochrome.
- **Fixed the stale charge indicator** — changing the limit (or pausing,
  calibrating, etc.) now updates the menu-bar icon and color within seconds instead
  of waiting for the next poll, so "started charging" shows right away.
- **Clearer Low Power Mode** — labeled to explain it lowers the ProMotion refresh
  rate, making it the obvious switch to restore full refresh rate after Super Saver.
- Added tooltips to the quick actions, the charge gauge, and Low Power Mode.

## 0.6.0

### Minor Changes

- **MagSafe LED modes** — Auto (macOS controls it) / Show status (orange charging,
  green holding the limit) / Off. Adds a post-wake "settling" window where the LED
  turns off and charging is briefly held before control resumes.
- **Stop charging before sleep** — cuts charging as the Mac sleeps so macOS can't
  top the battery past your limit overnight while the daemon is frozen.
- **Prevent idle sleep while plugged in** — optional power assertion (AC only) that
  keeps the limit continuously enforced.
- **Charge to 100% once** — one-tap calibration that temporarily ignores the limit
  and auto-reverts as soon as the battery is full.
- **Helper version handshake** — the app now detects and warns when the installed
  helper is older than it expects, instead of pause/other actions silently failing.

### Patch Changes

- **Battery indicator fixes** — the menu-bar glyph shows the real charge level, the
  charging bolt appears only while actually charging (not when paused), state color
  (green charging / red critically low) renders via a non-template image, and the
  icon updates reliably. Added a tooltip explaining why charging is paused.
- **Charge pause/resume reliability fixes** and a "settling after wake" status.
- **Lower energy use** — release builds are size-optimized and symbol-stripped, and
  all background polling timers now declare tolerance so macOS can coalesce wakeups.

## 0.5.0

### Minor Changes

- **Scheduled charge pause** — pause charging for 1h / 3h / 5h or until you resume;
  auto-resumes when the timer runs out, with remaining time shown in the menu.
- **MagSafe LED fix** — the LED re-asserts each tick (green when held/paused, orange
  while charging) so it reliably changes when charging stops.
- **Reverted licensing to offline Ed25519** (removed Gumroad); keys verify locally
  against an embedded public key, minted by `licensetool`.

### Patch Changes

- Native **monochrome** UI (system accent only; grayscale elsewhere) and a
  "Last closed" lid readout in the menu.

## 0.4.1

### Minor Changes

- **Quick Actions** — dim/brighten the display, turn the display off, and sleep the
  Mac from the menu. (Fan control omitted — locked & unsafe on Apple Silicon.)
- **UI refresh** — a charge gauge in the header marking where your limit sits,
  rounded numerals, icon-led section headers, and a cohesive battery-green accent.

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

# battlify

## 0.11.0

### Minor Changes

- d506d35: Add **Keep Awake (Caffeine)** mode — a one-tap "never off, never sleeps" toggle.

  A new tile in the menu's Quick Actions keeps the display from turning off and the
  Mac from idle-sleeping, the same thing `caffeinate -d` does.

  - Works on battery _and_ wall power (unlike the AC-gated "Always Active" keep-awake).
  - Needs no root and no helper daemon — it's a user-space `PreventUserIdleDisplaySleep`
    power assertion held by the app, so it works even before the helper is installed.
  - Tap to hold indefinitely, or press-and-hold the tile for a timed session (30 min /
    1 / 2 / 5 hours) that auto-releases.
  - Closing the lid still sleeps the Mac, and the assertion is released the instant
    Battlify quits — so it can never leave the Mac stuck awake.

  Also bootstraps the project's **first automated tests**: a `BattlifyKitTests` suite
  (swift-testing) covering the Caffeine state machine, timer expiry/cancellation, and a
  system-level integration test that asserts the real IOKit power assertion is
  registered and cleared — plus toggle benchmarks. Run with `./scripts/test.sh`; a new
  CI workflow runs them on every push/PR.

- d506d35: Animated menu-bar battery icons.

  - New "Pixel" icon style: a chunky 8-bit battery with notched corners. While
    charging, its fill sweeps from the current level up to full, one column at a
    time — like a classic handheld.
  - Every other style's charging bolt now gently pulses while charging.
  - When charging completes — the battery reaches 100% or lands at your charge
    limit — the icon flashes green a few times (or blinks monochrome when icon
    coloring is off), then settles.
  - Micro-details: animations respect the system Reduce Motion setting, never run
    while discharging (a battery saver shouldn't spend cycles on battery), and the
    driving timer only exists while an animation is actually visible.

### Patch Changes

- d506d35: Fix Always Active leaving the internal display and keyboard backlight on with the lid
  closed. Keeping the Mac awake with the lid shut skips macOS's normal clamshell
  display-off, and the previous one-shot display sleep didn't hold. Battlify now
  re-issues a forced display sleep while the lid is shut and Always Active is holding —
  so the panel and keyboard backlight go dark and stay dark — and it never runs when an
  external display is attached, so a docked monitor is untouched.
- d506d35: Relicense under the PolyForm Noncommercial License 1.0.0. You may use, modify, and
  contribute to Battlify freely for noncommercial purposes; selling it or using it
  commercially (paid products, hosted services, enterprise support) is not permitted. All
  commercial rights are reserved by the author.
- d506d35: Performance: cut needless background wakeups. Live-watts polling now runs only while
  the popover or Details window is open (instead of every 5 seconds for the app's whole
  life), the daemon caches its `pmset` reads longer so periodic status polls stop forking
  processes, and status refreshes only publish state that actually changed. Lower energy
  impact with no change in behaviour.
- d506d35: Fix the helper installer failing intermittently on reinstall/auto-update.

  The install scripts unloaded the LaunchDaemon (`launchctl bootout`) and immediately
  reloaded it (`launchctl bootstrap`). `bootout` is asynchronous, so bootstrapping
  before the old job finished tearing down races and fails with `Bootstrap failed: 5:
Input/output error` — and because the scripts run under `set -e`, that aborted the
  install and made the app report "Install cancelled or failed." This bit the common
  path now that the app auto-reinstalls the helper whenever it's out of date.

  - Wait for the old daemon instance to fully unload before bootstrapping, then retry
    bootstrap while the label frees up (and treat an already-loaded service as
    success, kickstarting it onto the new binary).
  - `launchctl enable` the service before bootstrap, so a service left disabled by a
    prior failed install can still load.
  - Strip the quarantine flag from the installed helper binary, so the (not-yet-
    notarized) daemon isn't killed by Gatekeeper right after install.

  Applies to both the app-bundled installer and `scripts/install-helper.sh`.

- d506d35: Make the app relaunch reliably after an in-app update.

  The post-update relaunch fired a single `open` and assumed it worked. It now
  re-registers the swapped bundle, waits briefly for Launch Services to settle, then
  relaunches with `open -n` and verifies the process actually came up — retrying a
  few times (checking first, so it never spawns a duplicate) and falling back to a
  launch by bundle id. If the app still isn't visible it logs a warning instead of
  silently giving up.

## 0.10.1

### Patch Changes

- 20e83a7: Fix the missing app icon in notifications.

  macOS Notification Center resolves the app icon through a compiled asset catalog
  (`Assets.car` referenced by `CFBundleIconName`), which the bundle didn't include —
  so notification banners showed a blank placeholder even though Finder and the Dock
  looked fine. The build now compiles an asset catalog with `actool` (and only sets
  `CFBundleIconName` when that catalog is actually present, so it never points at a
  missing target). `scripts/make-icon.sh` also emits the catalog source from the SVG
  master.

## 0.10.0

### Minor Changes

- 1d4e145: New app icon.

  A dark, premium "graphite" mark: a near-black squircle with a machined bevel and a
  brushed-metal battery whose three charge bars glow green. Ships as `AppIcon.icns`
  in the bundle (referenced via `CFBundleIconFile`), with the vector master at
  `branding/battlify-icon.svg` and a `scripts/make-icon.sh` to regenerate the iconset.

### Patch Changes

- bcf8b04: Fix save mode / charge settings resetting on their own.

  - **Lid-close deep save** ("Super save on lid close") no longer re-applies a whole save mode on wake. It now restores only what it actually changed — Low Power Mode and the sleep/wake toggles — so your custom charge limit and heat settings survive a lid close/open cycle, and the mode can no longer silently reset to **Off** when it couldn't be read at sleep.
  - **Switch mode by Wi-Fi network** no longer re-applies the mode that's already active (on launch or reconnect), which previously overwrote custom charge-limit/heat tweaks made within that mode.

## 0.9.3

### Patch Changes

- a546cbf: Always Active: optional "Also keep awake on battery".

  "Always Active" still defaults to AC-power-only (it releases when you unplug), but a new opt-in sub-toggle in Settings lets it keep the Mac awake with the lid closed on battery too. Off by default because a closed, unventilated Mac kept awake on battery drains fast and can run hot — the temperature guardrail still applies as a safety net, and the display/keyboard backlight still switch off to save power.

## 0.9.2

### Patch Changes

- 28119c5: Fix force-discharge ("Discharge to limit" / recharge range) not draining the battery.

  Cutting the power adapter to run off the battery makes macOS report the power source as "Battery Power", so the daemon read itself as unplugged on the very next tick, restored the adapter, and oscillated the adapter on/off every ~10s — the battery barely drained and the charge indicators flickered.

  - The daemon now gates discharge on **physical adapter presence** (the raw SMC `AC-W` key, which stays true through a force-discharge, falling back to IOKit's `ExternalConnected`) instead of the providing-source flag. Discharge now runs continuously until it reaches the limit (or the cable is genuinely unplugged).
  - Same fix applied to the MagSafe status LED (no longer flips to "Auto" mid-discharge), the prevent-idle-sleep assertion (no longer drops and lets the Mac sleep before draining finishes), and keep-awake.
  - Bumps the helper build version so an already-installed daemon auto-updates.

## 0.9.1

### Patch Changes

- 3073d57: Battery capacity mAh now matches the health percentage.

  The Details view derived "Maximum capacity" (%) from `NominalChargeCapacity` (matching macOS System Settings) but printed the "Capacity" mAh from `AppleRawMaxCapacity`, so the two disagreed — e.g. 5133/6249 mAh (82%) shown right beside a Health of 85%. Both now use the same figure, so the mAh ratio equals the percentage and matches macOS. Verified every displayed value (charge %, charging/plugged state, time remaining, cycles, temperature, health, capacity, and watts) against `pmset`, `ioreg`, and `system_profiler`.

- 86829c6: Premium HugeIcons menu-bar battery + selectable icon themes.

  The menu-bar battery is now drawn from HugeIcons' battery geometry and you can pick from four looks in Settings › Menu Bar: **Rounded** (HugeIcons squircle, smooth proportional fill — the new default), **Bars** (squircle with discrete level bars), **Classic** (traditional rectangular battery), and **Minimal** (clean capsule). All styles fill to your exact charge and draw the charging bolt inside the glyph, and they keep the adaptive template look plus the low/warm/charging colours.

- 71b305b: Always Active: turn off the display and keyboard backlight while the lid is closed.

  When "Always Active" is holding the Mac awake and you close the lid, the daemon now forces the display to sleep (the keyboard backlight follows it) so background jobs keep running without the hidden panel and backlight draining power. It re-triggers each time the lid closes and resets when the lid opens or keep-awake stops holding.

- 621aadc: Subtle animations and micro-interactions in the menu popover and Settings.

  The charge bar now fills with a spring and the limit marker slides when values change; the big percentage rolls with a numeric-text transition; the bar gains a gentle breathing glow while charging; quick-action buttons have press + hover feedback; and the battery-style tiles lift on hover with a spring selection. All motion lives in views that only render while open (popover / Settings), so idle CPU stays at ~0% and the always-visible menu-bar icon is never animated — no background drain on a battery app.

- 5f294f5: Notifications: register at launch, cleaner content, no emojis.

  When notifications are enabled, the app now registers with the system at launch (via a shared authorization path) instead of waiting for an unpredictable state change, so it shows up in System Settings › Notifications and can deliver. Alerts are grouped under one thread and a same-kind alert is cleared (pending and delivered) before re-posting so they don't stack. Removed the emoji from the test-notification message; the charge alerts (limit, heat, low, full) stay plain text.

- 6a600dd: Menu-bar battery icon now fills proportionally to the exact charge.

  The status-item battery was drawn with SF Symbols, which only offer five fixed fills (0/25/50/75/100), so the level appeared to jump in big steps and looked unchanged for wide percentage ranges. It's now a custom-drawn battery whose inner fill width tracks the real percentage, while keeping the adaptive template look and the low/warm/charging colours.

## 0.8.4

### Patch Changes

- Build the released binary on macOS 26 (was macOS 15). A binary built against the
  macOS 15 SDK silently failed to launch (exited immediately) on macOS 26 due to a
  Swift concurrency runtime mismatch — even though the same source runs fine when
  built on macOS 26. No code change; this rebuilds the release on the matching SDK.

## 0.8.3

### Patch Changes

- **Fixed another launch/enable crash.** Two more `MainActor.assumeIsolated` calls
  (the lid sleep/wake callbacks) could trap on macOS 26 when the callback wasn't on
  the main actor's executor — the same isolation-assertion crash. All such calls now
  hop safely with `Task { @MainActor }`.
- **Notifications now guide you instead of doing nothing.** Turning notifications on
  requests permission if it's undetermined, and if it's denied it opens an alert
  pointing to System Settings › Notifications rather than silently failing.
- **Restored the smooth, rounded menu.** Removed a custom background layer that made
  the popover look flat/square in the production build; it's back to the native
  translucent rounded style.

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

<div align="center">

# Battlify

**Make macOS stop wrecking your battery.**

Charge limiting, heat-aware charging, sleep-safe enforcement, and one-tap save
modes — all from your menu bar, built for Apple Silicon.

<a href="https://battlify.gumroad.com/l/battlify"><b>Download</b></a> ·
<a href="https://github.com/broisnischal/battlify/releases"><b>Releases</b></a> ·
<a href="https://github.com/broisnischal/battlify/issues"><b>Feedback</b></a>

![Platform](https://img.shields.io/badge/macOS-14%2B-blue)
![Arch](https://img.shields.io/badge/Apple%20Silicon-arm64-black)
![Price](https://img.shields.io/badge/price-%242.99-green)
![License](https://img.shields.io/badge/license-Battlify%20License-lightgrey)

</div>

## Why Battlify exists

Lithium batteries wear out fastest when they sit at a high charge and when they
run hot. macOS does both by default: it keeps you topped up at 100% and lets the
machine cook while it's docked and closed. Apple's own "Optimized Charging" tries
to help, but it's a black box — it decides when to hold at 80%, and you can't.

Battlify hands you the controls directly. Pick a charge ceiling and it holds
there. Tell it to stop charging when the battery gets warm and it will. It's a
small menu-bar app that does one thing well, and it stays out of your way the rest
of the time.

## What it does

**Charging & longevity**

- **Charge limit** — cap charging anywhere from 50–100%. Battlify holds the level
  with a hysteresis band so it isn't flicking the charger on and off at the
  threshold. It speaks both Apple Silicon SMC schemes (legacy `CH0B`/`CH0C` and
  the newer `CHTE` on macOS 26 "Tahoe").
- **Heat-aware charging** — pause charging when the battery climbs past a
  temperature you set, then resume once it cools. The menu tells you *why* charging
  is paused, so it never looks broken.
- **Discharge to the limit** — on Macs that support adapter control, if you plug in
  above your limit Battlify can run off the battery until it drifts back down,
  instead of just waiting.
- **Charge to 100% once** — one tap temporarily lifts the limit for a full charge
  (handy before a trip), then reverts itself the moment the battery is full. Good
  for the occasional full cycle a battery actually likes.

**Sleep-safe enforcement**

The catch with any charge limiter: the enforcer can't run while the Mac is asleep,
so a naive limiter lets macOS quietly charge to 100% overnight. Battlify closes
that gap two ways, and you choose which:

- **Stop charging before sleep** — cuts charging as the machine goes to sleep, so
  it can't top up past your limit while nothing's watching.
- **Prevent idle sleep while plugged in** — holds a power assertion (only on wall
  power, never on battery) so the limit stays continuously enforced.

**MagSafe LED**

- Drive the MagSafe LED from the actual charge state: **orange** while charging,
  **green** when it's holding at your limit, and **off** briefly right after wake
  while charging settles. Or force it **off**, or hand it back to macOS — three
  modes, your call. Only shows up on Macs that have a controllable LED.

**Save modes & lid automation**

- **One-tap Save Modes** — *Off / Normal / Super Saver* flip a whole bundle of
  settings at once instead of hunting through toggles.
- **Super Save when the lid closes** — closing the lid drops into maximum savings
  (Low Power Mode, sleep wake-ups off, Wi-Fi and Bluetooth off) and opening it puts
  everything back the way you left it.
- **Sleep & Idle controls** — Power Nap, wake-for-network, and TCP keep-alive are
  the settings that silently wake your Mac in a bag. Turn them off from one place.

**Insight & convenience**

- **Battery Health** card with the numbers that matter (cycle count, capacity,
  temperature) and plain-language tips.
- **Usage history** charts, plus a per-close readout of how much charge a closed-lid
  session actually cost you.
- **Lid / clamshell sensor** that warns you when you're docked-and-closed at a high
  charge — the worst-case aging scenario.
- **Quick Actions** — dim or brighten the display, blank it, or sleep the Mac.
- **Launch at login** and **in-app auto-update**, and it'll tell you if the helper
  ever falls out of date so features don't silently stop working.

## How it works

Writing SMC keys needs root, but you don't want a GUI running as root. So Battlify
splits in two:

- A **menu-bar app** that runs as you and never touches the SMC directly.
- A tiny **root helper** (`battlify-helper`), installed once as a LaunchDaemon. It
  owns the enforcement loop, auto-starts at every boot, and talks to the app over a
  local socket.

If the helper is ever stopped or killed, it re-enables charging on the way out — so
Battlify can never leave your Mac unable to charge.

## Performance

Battlify is a native Swift app, and it's built to be a quiet background citizen:

- **Event-driven, not busy.** Charge and power-source changes arrive as IOKit
  notifications; the fallback timers are slow and declare scheduling *tolerance*, so
  macOS batches their wake-ups with other work instead of spinning up the CPU on a
  fixed beat. Expensive things (like listing energy-hungry processes) only run while
  you're actually looking at them.
- **Menu-bar only.** No Dock icon, no window kept alive in the background — the UI
  is built on demand when you open the menu.
- **Small, lean builds.** Release binaries are size-optimized and symbol-stripped,
  and the root helper is a minimal daemon with no UI at all.

A note on memory, since people ask: a native Cocoa/SwiftUI app's "Memory" figure in
Activity Monitor is dominated by *shared* system framework pages that every app
counts — it isn't private cost. The honest metric for a battery tool is **energy
impact and wake-ups**, and Battlify is tuned to keep both low. It won't fit in a few
megabytes (no framework-linked app does), but it also won't sit there draining you.

## Install

1. Download the latest `Battlify.dmg` from
   [Releases](https://github.com/broisnischal/battlify/releases) and drag
   **Battlify** into Applications.
2. If macOS claims the app is "damaged," that's just Gatekeeper on a build it hasn't
   notarized yet — it isn't damaged. Clear the quarantine flag:
   ```bash
   sudo xattr -r -d com.apple.quarantine /Applications/Battlify.app
   ```
   (Not needed once the build is notarized.)
3. Launch it — it lives in the menu bar, not the Dock.
4. Click **Install Helper…** in the menu (one password prompt). The helper is a
   LaunchDaemon, so it starts at boot and keeps running on its own.

### Recommended: turn off macOS's own charge management

For Battlify's limit to behave predictably, disable Apple's competing feature:

- **System Settings → Battery → Battery Health → ⓘ → turn off "Optimized Battery
  Charging."**
- On **macOS 26.4+**, also turn off the built-in **Charge Limit** there.

## Pricing

**Free for 30 days.** Your free days are only spent on days you *actually use*
Battlify, so you get the full month of real use without a countdown breathing down
your neck.

**$2.99 to own.** One-time payment (plus tax) — no subscription, no add-ons. Pay
with **Apple Pay** in a couple of taps, in-app or
[here](https://battlify.gumroad.com/l/battlify).

## Build from source

Requires the Swift toolchain (Xcode or the Command Line Tools), macOS 14+, and an
Apple Silicon Mac.

```bash
swift build
swift run Battlify                 # run the menu-bar app
sudo ./scripts/install-helper.sh   # install the root helper daemon

./scripts/package-app.sh 0.6.0     # build Battlify.app
./scripts/make-dmg.sh 0.6.0        # build the DMG
```

See [`DISTRIBUTION.md`](DISTRIBUTION.md) for signing, notarization, the GitHub
Actions release pipeline, Gumroad setup, and the auto-update feed.

## Contributing & releases

This repo uses [Changesets](https://github.com/changesets/changesets):

```bash
npm install
npm run changeset      # describe your change (patch / minor / major)
```

Commit the generated `.changeset/*.md`. Merging the auto-opened "Version Packages"
PR bumps the version and `CHANGELOG.md`; pushing that version tag triggers the
release build.

The app and helper speak a small versioned protocol over their socket. When you
change what the daemon does, bump `ControlProtocol.version` — the app compares it to
the running helper and warns when the installed helper is out of date, and you'll
need to reinstall it (`sudo ./scripts/install-helper.sh`) for the change to take
effect.

## License

Battlify is **source-available** under the [Battlify License](LICENSE): do almost
anything with the source, with protections against malicious or rip-off
redistributions of the *app itself*.

## Credits

Charge-control SMC keys and MagSafe LED behavior were learned from
[batt](https://github.com/charlie0129/batt) and
[battery](https://github.com/actuallymentor/battery). Thanks to those projects.

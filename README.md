# BattPie

A menu-bar **battery saver** for Apple Silicon Macs. Monitors your battery,
limits charging to protect long-term health, optimizes power, charts usage
history, and automates radios when you close the lid.

> macOS 14+ (built & tested on macOS 26 "Tahoe"), Apple Silicon.

## Features

- **Battery monitoring** — live %, health, cycle count, temperature, capacity,
  time-to-full/empty in the menu bar.
- **Charge limiting** — cap charging at a chosen level (e.g. 80%) via the SMC,
  with hysteresis to avoid toggle-thrashing. Handles both the legacy
  (`CH0B`/`CH0C`) and Tahoe (`CHTE`) charging schemes automatically.
- **Power optimization** — toggle Low Power Mode; see top energy-using processes
  and suspend/resume them.
- **Usage history** — battery % and temperature charted over 6h / 24h / 7d
  (Swift Charts). Sampled every 5 minutes.
- **Lid-close automation** — turn off Wi-Fi and/or Bluetooth when you close the
  lid, and optionally restore them on wake.

## Architecture

```
BattPie.app (runs as you)            battpie-helper (runs as root, LaunchDaemon)
├─ menu bar UI (SwiftUI)             ├─ enforces charge limit via SMC
├─ battery monitoring (IOKit)        ├─ toggles Low Power Mode (pmset)
├─ lid automation (CoreWLAN, BT)     ├─ records history
└─ talks to helper ───────────────►  └─ control socket  /var/run/battpie.sock
```

Writing SMC keys and toggling Low Power Mode require root, so those run in a
small privileged daemon. The GUI talks to it over a local Unix socket; it never
touches privileged APIs directly. **Safety:** the daemon re-enables charging on
exit/crash, so the Mac is never stranded.

## Build & run (development)

```bash
swift build
swift run BattPie          # menu-bar app
```

Charge limiting / Low Power Mode need the daemon:

```bash
sudo ./scripts/install-helper.sh     # builds + installs the LaunchDaemon
```

Helper CLI (handy for testing):

```bash
./.build/debug/battpie-helper dump   # SMC diagnostics (no root)
sudo ./.build/debug/battpie-helper disable   # stop charging
sudo ./.build/debug/battpie-helper enable    # resume
sudo ./.build/debug/battpie-helper limit 80  # set + enable 80% limit
```

## Package a distributable app

```bash
./scripts/package-app.sh 0.1.0       # -> dist/BattPie.app + dist/BattPie-0.1.0.zip
```

The bundle includes the helper + installer, so users can click **Install
Helper…** in the app instead of using the command line.

## Install via Homebrew

After publishing `BattPie-<version>.zip` to a GitHub release and filling in the
`url`/`sha256` in `Casks/battpie.rb`:

```bash
brew install --cask ./Casks/battpie.rb      # local tap
# or, once tapped:
brew install --cask battpie
```

## Uninstall

```bash
sudo ./scripts/uninstall-helper.sh   # removes daemon, re-enables charging
```

## Notes & limitations

- **Bluetooth toggle** uses a private IOBluetooth symbol — it works but could
  break in a future macOS update.
- **Lid close on battery** sleeps the Mac; radios are toggled in the brief
  pre-sleep window. "Do things *while* the lid stays closed" isn't possible
  unless the Mac is kept awake (power + external display).
- **Personal Hotspot / Internet Sharing** toggling is intentionally omitted —
  macOS exposes no reliable API for it.
- Not sandboxed / not for the Mac App Store (charge limiting needs SMC + a root
  helper, which the sandbox forbids).

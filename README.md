# Battlify

A native menu-bar **battery saver and health guardian** for Apple Silicon Macs.
Battlify monitors your battery, limits charging to protect long-term health,
pauses charging when it gets too hot, optimizes sleep/idle power, charts usage
history, and surfaces what's actually draining your battery.

> macOS 14+ (built & tested on macOS 26 "Tahoe"), Apple Silicon only.

## Features

### One-tap Save Modes
Pick a profile and Battlify applies the whole bundle at once:

| Mode | Charge limit | Pause when hot | Low Power Mode | Sleep wake-ups | Wi-Fi/BT on lid close |
|------|:---:|:---:|:---:|:---:|:---:|
| **Off** | — | — | off | default | no |
| **Normal** | 80% | 35 °C | off | Power Nap off | no (Find My stays on) |
| **Super Saver** | 80% | 33 °C | on | all off | both off |

### Charge limiting
- Cap charging at a chosen level (50–100%) to reduce time at high charge — the
  #1 controllable cause of battery wear.
- Handles both Apple-Silicon charging schemes automatically: legacy
  `CH0B`/`CH0C` and the macOS 26 "Tahoe" `CHTE` key.
- Hysteresis avoids rapid charge on/off toggling at the threshold.

### Heat-aware charging
- Automatically pauses charging when the battery exceeds a temperature you set
  (30–45 °C). Heat + charging is the biggest accelerant of battery aging.
- The menu tells you *why* charging paused — too hot 🌡️ vs holding the limit ⏸️.

### Battery health
- Health %, condition (Normal / Service Recommended), and cycle count.
- **State-aware tips** that adapt to your situation (warm battery, sitting at
  100% on AC, limit disabled, etc.).

### Sleep & idle power
- Turn off **Wi-Fi** and/or **Bluetooth** when you close the lid; restore on wake.
- Toggle the system sleep behaviors that silently drain battery while closed:
  **Power Nap**, **wake for network access**, and **TCP keep-alive**.

### Power & processes
- Toggle **Low Power Mode**.
- See the **top energy-using processes** and suspend/resume them (SIGSTOP/SIGCONT).

### Usage history
- Battery % and temperature charted over 6h / 24h / 7d (Swift Charts), sampled
  every 5 minutes — even while logged out (the daemon records it).

## Architecture

```
Battlify.app (runs as you)           battlify-helper (runs as root, LaunchDaemon)
├─ menu bar UI (SwiftUI)             ├─ enforces charge limit + heat-aware (SMC)
├─ battery monitoring (IOKit)        ├─ toggles Low Power Mode & sleep settings (pmset)
├─ lid automation (CoreWLAN, BT)     ├─ records history
├─ Details & History windows         └─ control socket  /var/run/battlify.sock
└─ talks to helper ───────────────►
```

Writing SMC keys and toggling power settings require root, so those run in a
small privileged daemon. The GUI talks to it over a local Unix socket and never
touches privileged APIs directly. **Safety:** the daemon re-enables charging on
exit/crash (and when uninstalled), so the Mac is never left unable to charge.

```
Sources/
├── CSMC/              C SMC read/write layer
├── BattlifyKit/       shared: SMC, ChargeController, Config, Control, Modes, History
├── Battlify/          menu-bar GUI + Details/History windows
└── battlify-helper/   root daemon: enforcement loop + control socket
```

## Build & run (development)

```bash
swift build
swift run Battlify          # menu-bar app
```

Charge limiting, heat-aware charging, Low Power Mode, and the sleep toggles need
the root daemon:

```bash
sudo ./scripts/install-helper.sh     # builds + installs the LaunchDaemon
```

Helper CLI (handy for testing):

```bash
./.build/debug/battlify-helper dump          # SMC diagnostics (no root)
sudo ./.build/debug/battlify-helper disable  # stop charging
sudo ./.build/debug/battlify-helper enable   # resume
sudo ./.build/debug/battlify-helper limit 80 # set + enable 80% limit
```

## Package a distributable app

```bash
./scripts/package-app.sh 0.1.0       # -> dist/Battlify.app + dist/Battlify-0.1.0.zip
```

The bundle includes the helper + installer, so users can click **Install
Helper…** in the app instead of using the command line.

## Install via Homebrew

After publishing `Battlify-<version>.zip` to a GitHub release and filling in the
`url`/`sha256` in `Casks/battlify.rb`:

```bash
brew install --cask ./Casks/battlify.rb     # local
# or, once tapped:
brew install --cask battlify
```

## Uninstall

```bash
sudo ./scripts/uninstall-helper.sh   # removes daemon, re-enables charging
```

## Notes & limitations

- **Bluetooth toggle** uses a private IOBluetooth symbol — it works but could
  break in a future macOS update.
- **Lid close on battery** sleeps the Mac; radios are toggled in the brief
  pre-sleep window. Keeping things running *while* the lid stays closed isn't
  possible unless the Mac is kept awake (power + external display).
- **Personal Hotspot / Internet Sharing** toggling is intentionally omitted —
  macOS exposes no reliable API for it.
- Not sandboxed / not for the Mac App Store (charge limiting needs SMC + a root
  helper, which the sandbox forbids).

<div align="center">

<!-- Replace with Markdown/Media/AppIcon.png once you've made the icon -->
<img src="Markdown/Media/AppIcon.png" width="180" height="auto" alt="Battlify">

# Battlify

**Make macOS stop wrecking your battery.**

Charge limiting · heat-aware charging · one-tap save modes · deep sleep savings · battery-health insights — all from your menu bar.

<a href="https://battlify.gumroad.com/l/battlify"><b>Download</b></a> ·
<a href="https://github.com/broisnischal/battlify/releases"><b>Releases</b></a> ·
<a href="https://github.com/broisnischal/battlify/issues"><b>Feedback</b></a>

![Platform](https://img.shields.io/badge/macOS-14%2B-blue)
![Arch](https://img.shields.io/badge/Apple%20Silicon-arm64-black)
![Price](https://img.shields.io/badge/price-%242.99-green)
![License](https://img.shields.io/badge/license-Battlify%20License-lightgrey)

<!-- Replace with a real screenshot -->
<img src="Markdown/Media/Screenshot.png" width="320" height="auto" alt="Battlify menu">

</div>

## Why Battlify

macOS keeps your battery topped up at 100% and lets it run hot while docked — the
two fastest ways to wear a battery out. Battlify gives you the controls Apple
doesn't, in a clean menu-bar app built for Apple Silicon.

## Features

- 🔋 **Charge limiting** — cap charging (50–100%) to cut time at high charge.
  Handles both Apple-Silicon SMC schemes (legacy `CH0B/CH0C` and Tahoe `CHTE`).
- 🔥 **Heat-aware charging** — automatically pause charging when the battery gets
  too warm, with a clear reason shown in the menu.
- ⚡ **One-tap Save Modes** — *Off / Normal / Super Saver* apply a whole bundle of
  settings at once.
- 😴 **Super Save when lid closed** — closing the lid maximizes battery (Low Power
  Mode, sleep wake-ups off, radios off) and opening it restores your state.
- 💤 **Sleep & Idle controls** — Power Nap, wake-for-network, TCP keep-alive — the
  settings that silently wake your Mac while it's closed.
- 🖥️ **Lid / clamshell sensor** with a docked-mode health warning.
- 📊 **Usage history** charts and a **Battery Health** card with actionable tips.
- 🚀 **Launch at Login** + **in-app auto-update**.

## Pricing

**Free for 30 days.** Your free days are only used up when you *actually use*
Battlify — so you get the most out of them, without any stress.

**$2.99 to own.** One-time payment (+ taxes). No subscriptions, no add-ons. The
checkout is quick and you can pay with **Apple Pay**. Buy in-app, or
[here](https://battlify.gumroad.com/l/battlify).

## Install

1. Download the latest `Battlify.dmg` from [Releases](https://github.com/broisnischal/battlify/releases)
   and drag **Battlify** to Applications.
2. Launch it — it lives in your menu bar (no Dock icon).
3. Click **Install Helper…** in the menu (one password prompt) to enable charge
   limiting, heat-aware charging, and the sleep controls. The helper safely
   re-enables charging if it ever stops.

> Battlify checks for updates automatically and offers a one-click download.

## Build from source

Requires the Swift toolchain (Xcode or Command Line Tools), macOS 14+, Apple Silicon.

```bash
swift build
swift run Battlify                 # run the menu-bar app
sudo ./scripts/install-helper.sh   # install the root helper daemon

./scripts/package-app.sh 0.2.0     # build Battlify.app
./scripts/make-dmg.sh 0.2.0        # build the DMG
```

See [`DISTRIBUTION.md`](DISTRIBUTION.md) for signing, notarization, the GitHub
Actions release pipeline, Gumroad setup, and the auto-update feed.

## Contributing & releases

This repo uses [Changesets](https://github.com/changesets/changesets):

```bash
npm install
npm run changeset      # describe your change (patch/minor/major)
```

Commit the generated `.changeset/*.md`. Merging the auto-opened "Version Packages"
PR bumps the version + `CHANGELOG.md`; tagging that version triggers a release.

## License

Battlify is **source-available** under the [Battlify License](LICENSE) — do almost
anything with the source, with protections against malicious or rip-off
redistributions of the *app*.

## Acknowledgements

- SMC charge-control keys referenced from
  [charlie0129/batt](https://github.com/charlie0129/batt) and
  [actuallymentor/battery](https://github.com/actuallymentor/battery).

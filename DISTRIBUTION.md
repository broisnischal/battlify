# Distributing & selling Battlify

This covers shipping Battlify as a **closed-source, paid** macOS app outside the
Mac App Store. (It can't go on the App Store — charge limiting needs SMC access
+ a root helper, which the sandbox forbids.)

## 1. Apple Developer setup (one-time, required)

You need an **Apple Developer Program** membership ($99/year). Without it,
Gatekeeper blocks downloaded apps with no clean way for buyers to open them.

1. **Developer ID Application certificate** — create in Xcode or the Apple
   Developer portal. Export it as a `.p12` (with a password). This signs the app.
2. **App Store Connect API key** (for notarization) — App Store Connect →
   Users and Access → Integrations → keys. Create a key with the **Developer**
   role. Download the `AuthKey_XXXX.p8` (you can only download it once). Note the
   **Key ID** and **Issuer ID**.

Why both: the certificate *signs* the app so macOS trusts the author;
**notarization** is Apple scanning the build and issuing a ticket so Gatekeeper
opens it without warnings. We staple the ticket into the DMG so it works offline.

## 2. GitHub secrets

Add these in the repo → Settings → Secrets and variables → Actions:

| Secret | What it is |
|--------|------------|
| `DEVELOPER_ID_CERT_P12_BASE64` | `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_CERT_PASSWORD` | password you set when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | any random string (ephemeral CI keychain) |
| `NOTARY_KEY_ID` | App Store Connect key ID |
| `NOTARY_ISSUER_ID` | App Store Connect issuer UUID |
| `NOTARY_KEY_P8_BASE64` | `base64 -i AuthKey_XXXX.p8 \| pbcopy` |

> macOS GitHub Actions runners bill minutes at a **10× multiplier**. On a private
> repo this eats your included minutes fast — expect to pay for build minutes, or
> build/notarize locally with the same scripts (see below).

## 3. Cutting a release

Tag and push:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The `Release` workflow builds → signs → notarizes → staples → creates a **draft**
GitHub Release with `Battlify-0.1.0.dmg`. Review it, then publish.

**Locally** (no CI), same result:

```bash
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export NOTARY_KEY_ID=...  NOTARY_ISSUER_ID=...  NOTARY_KEY_PATH=~/AuthKey_XXXX.p8
./scripts/package-app.sh 0.1.0
./scripts/make-dmg.sh 0.1.0
./scripts/notarize.sh dist/Battlify-0.1.0.dmg
```

## 4. Selling it (payments + licensing)

You don't sell through GitHub. Host the notarized DMG behind a storefront and
gate the app with a **license key**:

| Option | Notes |
|--------|-------|
| **Paddle** / **Lemon Squeezy** | Merchant of record — they handle VAT/sales tax worldwide and can issue & verify license keys. Easiest for a solo paid Mac app. |
| **Gumroad** | Simple, has license keys via API. Takes a cut. |
| **Stripe** | Lowest fees, most control, but you handle tax + build your own key server. |

**License enforcement approach (recommended): offline signature checks.**
- Generate an Ed25519 keypair. Keep the private key secret (on your storefront's
  license server / webhook).
- Each purchase mints a license = signed payload (email, expiry, etc.).
- Embed only the **public key** in the app; verify the signature locally. No
  phone-home required, hard to forge, works offline.
- Add a grace/trial period and a "Enter license" window.

**This is already built.** Battlify ships with offline Ed25519 licensing:
- `Sources/BattlifyKit/License.swift` — verifies tokens against an embedded public key.
- `LicenseManager` / `LicenseView` — 14-day trial, activation window, control gating.
- `licensetool` — the seller-side key generator + signer (not bundled in the app).

**Minting keys & licenses:**

```bash
swift run licensetool genkey
# → prints a PRIVATE key (keep secret) and a PUBLIC key.
#   Paste the PUBLIC key into License.publicKeyBase64 and REBUILD.
#   ⚠️ The key currently embedded is a TEST key — regenerate yours privately.

# Mint a license (your storefront webhook runs this with the private key):
swift run licensetool sign --priv <PRIVATE_B64> --email buyer@x.com --name "Buyer" --days 365
# → a license token the buyer pastes into Battlify's Activate window.
#   Omit --days for a perpetual license.

swift run licensetool verify --token <TOKEN>   # sanity-check a token
```

**Wiring to a storefront:** point Paddle/Lemon Squeezy's "license generation"
webhook at a tiny endpoint that runs the equivalent of `sign` and returns the
token to the buyer (email + license page). Keep the private key only on that server.

## 5. Homebrew note

A public Homebrew cask means anyone can `brew install` it for free, which
conflicts with charging. For a paid app, **drop the public cask** (or keep one
that only fetches a free/trial build). `Casks/battlify.rb` is kept in-repo for
reference / a future free tier.

## 6. Auto-update

Battlify checks a **public JSON feed** (`appcast.json`) on launch + daily and shows
an in-app "Update available" banner with a one-click download.

- Feed format: `{ "version": "0.2.0", "url": "https://…/Battlify-0.2.0.dmg", "notes": "…" }`
- The app reads `UpdaterManager.feedURL` (currently
  `raw.githubusercontent.com/broisnischal/battlify-releases/main/appcast.json`).
- The release workflow generates `dist/appcast.json` (via `scripts/make-appcast.sh`)
  and attaches it to the GitHub Release.

**Hosting (required, because the source repo is private):** create a **public**
place for the feed + DMGs so users can reach them without auth. Easiest options:
- A public `battlify-releases` repo: commit `appcast.json` there and upload DMGs
  to its Releases. Point `feedURL` at its `raw.githubusercontent.com/...` path.
- GitHub Pages, or your storefront/CDN.

Then per release: build → upload the DMG to the public location → update
`appcast.json` there with the new version/url.

**Full silent install (future):** for true "download + install + relaunch" with no
manual drag, integrate **Sparkle** (`sparkle-project/Sparkle`). It needs Apple
notarization and bundling Sparkle's XPC services into the `.app` — worth doing once
you're enrolled and notarizing. The current updater is the no-notarization-needed
stepping stone.

## 7. Icons & branding (later)

Add `Battlify.icns` to the bundle: create an `AppIcon.iconset` (16–1024 px),
`iconutil -c icns AppIcon.iconset`, drop the `.icns` in `Contents/Resources`, and
set `CFBundleIconFile` in `package-app.sh`'s Info.plist. The menu-bar glyph is
already an SF Symbol; you can swap it for a custom template image later.

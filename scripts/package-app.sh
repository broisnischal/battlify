#!/bin/bash
# Builds Battlify.app (a proper menu-bar app bundle) and a distributable zip.
# Usage: ./scripts/package-app.sh [version]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.1.0}"
APP="Battlify.app"
DIST="$REPO_DIR/dist"
APP_DIR="$DIST/$APP"
CONTENTS="$APP_DIR/Contents"
BUNDLE_ID="com.battlify.app"

echo "==> Building release binaries (v$VERSION)…"
cd "$REPO_DIR"
# Optimize for size (-Osize) and let the linker drop unreachable code
# (-dead_strip). Smaller text pages → smaller footprint, no behavior change.
BUILD_FLAGS=(-c release -Xswiftc -Osize -Xlinker -dead_strip)
swift build "${BUILD_FLAGS[@]}" --product Battlify
swift build "${BUILD_FLAGS[@]}" --product battlify-helper
BIN_DIR="$REPO_DIR/.build/release"

echo "==> Assembling $APP"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

# Main GUI binary.
cp "$BIN_DIR/Battlify" "$CONTENTS/MacOS/Battlify"
chmod 755 "$CONTENTS/MacOS/Battlify"

# Bundle the helper + daemon plist + installer so the app can self-install it.
cp "$BIN_DIR/battlify-helper" "$CONTENTS/Resources/battlify-helper"
cp "$REPO_DIR/scripts/com.battlify.helper.plist" "$CONTENTS/Resources/"
cp "$REPO_DIR/scripts/install-helper-bundled.sh" "$CONTENTS/Resources/"
cp "$REPO_DIR/scripts/uninstall-helper.sh" "$CONTENTS/Resources/"
chmod 755 "$CONTENTS/Resources/battlify-helper" \
          "$CONTENTS/Resources/install-helper-bundled.sh" \
          "$CONTENTS/Resources/uninstall-helper.sh"

# Strip local/debug symbols before signing (must precede codesign or it would
# invalidate the signature). -x keeps external symbols, so nothing breaks.
strip -x "$CONTENTS/MacOS/Battlify"
strip -x "$CONTENTS/Resources/battlify-helper"

# Info.plist — LSUIElement makes it a menu-bar-only (agent) app.
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>Battlify</string>
    <key>CFBundleDisplayName</key>      <string>Battlify</string>
    <key>CFBundleIdentifier</key>       <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>       <string>Battlify</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>          <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>   <string>14.0</string>
    <key>LSUIElement</key>              <true/>
    <key>NSHumanReadableCopyright</key> <string>Battlify</string>
    <!-- Required: Battlify toggles Bluetooth power on lid close. Without this
         usage string macOS kills the app (TCC) when it touches Bluetooth. -->
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Battlify turns Bluetooth off when you close the lid and back on when you reopen it, to save battery.</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>Battlify turns Bluetooth off when you close the lid and back on when you reopen it, to save battery.</string>
</dict>
</plist>
PLIST

# Signing. Set CODESIGN_IDENTITY to a "Developer ID Application: …" identity for
# a distributable, notarizable build; otherwise we ad-hoc sign for local use.
IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
    echo "==> Ad-hoc code signing (local use only — not notarizable)"
    SIGN_FLAGS=(--force --sign -)
else
    echo "==> Developer ID signing with hardened runtime: $IDENTITY"
    SIGN_FLAGS=(--force --options runtime --timestamp --sign "$IDENTITY")
fi

# Sign nested executables first, then the app bundle (no deprecated --deep).
codesign "${SIGN_FLAGS[@]}" "$CONTENTS/Resources/battlify-helper"
codesign "${SIGN_FLAGS[@]}" "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR" || echo "warning: verify failed"

echo "==> Creating zip"
cd "$DIST"
rm -f "Battlify-$VERSION.zip"
ditto -c -k --keepParent "$APP" "Battlify-$VERSION.zip"
shasum -a 256 "Battlify-$VERSION.zip"

echo "==> Done: $APP_DIR"
echo "    Run: open '$APP_DIR'"

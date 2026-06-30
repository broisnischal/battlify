#!/bin/bash
# Builds BattPie.app (a proper menu-bar app bundle) and a distributable zip.
# Usage: ./scripts/package-app.sh [version]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.1.0}"
APP="BattPie.app"
DIST="$REPO_DIR/dist"
APP_DIR="$DIST/$APP"
CONTENTS="$APP_DIR/Contents"
BUNDLE_ID="com.battpie.app"

echo "==> Building release binaries (v$VERSION)…"
cd "$REPO_DIR"
swift build -c release --product BattPie
swift build -c release --product battpie-helper
BIN_DIR="$REPO_DIR/.build/release"

echo "==> Assembling $APP"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

# Main GUI binary.
cp "$BIN_DIR/BattPie" "$CONTENTS/MacOS/BattPie"
chmod 755 "$CONTENTS/MacOS/BattPie"

# Bundle the helper + daemon plist + installer so the app can self-install it.
cp "$BIN_DIR/battpie-helper" "$CONTENTS/Resources/battpie-helper"
cp "$REPO_DIR/scripts/com.battpie.helper.plist" "$CONTENTS/Resources/"
cp "$REPO_DIR/scripts/install-helper-bundled.sh" "$CONTENTS/Resources/"
cp "$REPO_DIR/scripts/uninstall-helper.sh" "$CONTENTS/Resources/"
chmod 755 "$CONTENTS/Resources/battpie-helper" \
          "$CONTENTS/Resources/install-helper-bundled.sh" \
          "$CONTENTS/Resources/uninstall-helper.sh"

# Info.plist — LSUIElement makes it a menu-bar-only (agent) app.
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>BattPie</string>
    <key>CFBundleDisplayName</key>      <string>BattPie</string>
    <key>CFBundleIdentifier</key>       <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>       <string>BattPie</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>          <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>   <string>14.0</string>
    <key>LSUIElement</key>              <true/>
    <key>NSHumanReadableCopyright</key> <string>BattPie</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing (stable identity for TCC prompts)"
codesign --force --deep --sign - "$APP_DIR" || \
    echo "warning: codesign failed (continuing unsigned)"

echo "==> Creating zip"
cd "$DIST"
rm -f "BattPie-$VERSION.zip"
ditto -c -k --keepParent "$APP" "BattPie-$VERSION.zip"
shasum -a 256 "BattPie-$VERSION.zip"

echo "==> Done: $APP_DIR"
echo "    Run: open '$APP_DIR'"

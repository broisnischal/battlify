#!/bin/bash
# Builds a distributable DMG from dist/Battlify.app.
# Usage: ./scripts/make-dmg.sh [version]
# Run scripts/package-app.sh first (it produces dist/Battlify.app).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.1.0}"
DIST="$REPO_DIR/dist"
APP="$DIST/Battlify.app"
DMG="$DIST/Battlify-$VERSION.dmg"

if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found — run scripts/package-app.sh first." >&2
    exit 1
fi

echo "==> Staging DMG contents"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Battlify.app"
ln -s /Applications "$STAGE/Applications"   # drag-to-install target

echo "==> Building $DMG"
rm -f "$DMG"
hdiutil create -volname "Battlify" \
    -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# Sign the DMG itself when a Developer ID identity is available.
if [[ "${CODESIGN_IDENTITY:--}" != "-" ]]; then
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
fi

shasum -a 256 "$DMG"
echo "==> Done: $DMG"

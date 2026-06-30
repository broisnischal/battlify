#!/bin/bash
# Installs the BattPie helper daemon from a packaged .app bundle.
# This script lives in BattPie.app/Contents/Resources and copies the prebuilt
# helper next to it — it does NOT rebuild. Invoked by the app with admin rights.
set -euo pipefail

RES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_SRC="$RES_DIR/battpie-helper"
PLIST_SRC="$RES_DIR/com.battpie.helper.plist"
BIN_DST="/usr/local/bin/battpie-helper"
PLIST_DST="/Library/LaunchDaemons/com.battpie.helper.plist"
LABEL="com.battpie.helper"

if [[ "$EUID" -ne 0 ]]; then
    echo "error: must run as root." >&2
    exit 1
fi
if [[ ! -x "$BIN_SRC" ]]; then
    echo "error: bundled helper not found at $BIN_SRC" >&2
    exit 1
fi

install -d /usr/local/bin
install -m 755 "$BIN_SRC" "$BIN_DST"
install -m 644 "$PLIST_SRC" "$PLIST_DST"
chown root:wheel "$PLIST_DST"
install -d -m 755 "/Library/Application Support/BattPie"

launchctl bootout system "$PLIST_DST" 2>/dev/null || true
launchctl bootstrap system "$PLIST_DST"
launchctl enable "system/$LABEL" 2>/dev/null || true

echo "BattPie helper installed and loaded."

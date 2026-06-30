#!/bin/bash
# Removes the BattPie privileged helper LaunchDaemon.
# Run with sudo:  sudo ./scripts/uninstall-helper.sh
set -euo pipefail

PLIST_DST="/Library/LaunchDaemons/com.battpie.helper.plist"
BIN_DST="/usr/local/bin/battpie-helper"

if [[ "$EUID" -ne 0 ]]; then
    echo "error: must run as root (use sudo)." >&2
    exit 1
fi

echo "==> Re-enabling charging (safety) before removing daemon"
"$BIN_DST" enable 2>/dev/null || true

echo "==> Unloading daemon"
launchctl bootout system "$PLIST_DST" 2>/dev/null || true

echo "==> Removing files"
rm -f "$PLIST_DST"
rm -f "$BIN_DST"
rm -f /var/run/battpie.sock

echo "==> Done. (Config left in /Library/Application Support/BattPie)"

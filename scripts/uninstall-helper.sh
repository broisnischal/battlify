#!/bin/bash
# Removes the Battlify privileged helper LaunchDaemon.
# Run with sudo:  sudo ./scripts/uninstall-helper.sh
set -euo pipefail

PLIST_DST="/Library/LaunchDaemons/com.battlify.helper.plist"
BIN_DST="/usr/local/bin/battlify-helper"

if [[ "$EUID" -ne 0 ]]; then
    echo "error: must run as root (use sudo)." >&2
    exit 1
fi

echo "==> Unloading daemon"
launchctl bootout system "$PLIST_DST" 2>/dev/null || true

# Re-enable charging AFTER the daemon is unloaded: on exit the daemon now
# preserves the charge inhibit (so the limit survives shutdown/restart), so this
# must be the last word on the SMC — otherwise the daemon's exit cleanup would
# re-inhibit charging right after we cleared it, leaving the Mac unable to charge.
echo "==> Re-enabling charging (safety) after unloading daemon"
"$BIN_DST" enable 2>/dev/null || true

echo "==> Removing files"
rm -f "$PLIST_DST"
rm -f "$BIN_DST"
rm -f /var/run/battlify.sock

echo "==> Done. (Config left in /Library/Application Support/Battlify)"

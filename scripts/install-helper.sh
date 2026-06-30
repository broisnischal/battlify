#!/bin/bash
# Installs the BattPie privileged helper as a LaunchDaemon (runs as root).
# Run with sudo:  sudo ./scripts/install-helper.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DST="/usr/local/bin/battpie-helper"
PLIST_SRC="$REPO_DIR/scripts/com.battpie.helper.plist"
PLIST_DST="/Library/LaunchDaemons/com.battpie.helper.plist"
LABEL="com.battpie.helper"

if [[ "$EUID" -ne 0 ]]; then
    echo "error: must run as root (use sudo)." >&2
    exit 1
fi

echo "==> Building release binary…"
# Build as the invoking user so SwiftPM caches land in their home, not root's.
if [[ -n "${SUDO_USER:-}" ]]; then
    sudo -u "$SUDO_USER" bash -lc "cd '$REPO_DIR' && swift build -c release --product battpie-helper"
else
    (cd "$REPO_DIR" && swift build -c release --product battpie-helper)
fi
BIN_SRC="$REPO_DIR/.build/release/battpie-helper"

echo "==> Installing binary to $BIN_DST"
install -d /usr/local/bin
install -m 755 "$BIN_SRC" "$BIN_DST"

echo "==> Installing LaunchDaemon to $PLIST_DST"
install -m 644 "$PLIST_SRC" "$PLIST_DST"
chown root:wheel "$PLIST_DST"

echo "==> Creating config directory"
install -d -m 755 "/Library/Application Support/BattPie"

echo "==> Loading daemon"
launchctl bootout system "$PLIST_DST" 2>/dev/null || true
launchctl bootstrap system "$PLIST_DST"
launchctl enable "system/$LABEL" 2>/dev/null || true

echo "==> Done. Status:"
sleep 1
"$BIN_DST" status || true
echo
echo "Logs: /var/log/battpie-helper.log"
echo "To uninstall: sudo ./scripts/uninstall-helper.sh"

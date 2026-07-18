#!/bin/bash
# Installs the Battlify privileged helper as a LaunchDaemon (runs as root).
# Run with sudo:  sudo ./scripts/install-helper.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DST="/usr/local/bin/battlify-helper"
PLIST_SRC="$REPO_DIR/scripts/com.battlify.helper.plist"
PLIST_DST="/Library/LaunchDaemons/com.battlify.helper.plist"
LABEL="com.battlify.helper"

if [[ "$EUID" -ne 0 ]]; then
    echo "error: must run as root (use sudo)." >&2
    exit 1
fi

# Reload the LaunchDaemon robustly. `launchctl bootout` is asynchronous, so
# bootstrapping straight after it races the old job's teardown and fails with
# "Bootstrap failed: 5: Input/output error". Enable first (a previously disabled
# service can't bootstrap), wait for the old instance to fully unload, then
# bootstrap with a short retry while the label frees up.
reload_daemon() {
    local plist="$1" label="$2"
    local errfile; errfile="$(mktemp)"

    launchctl enable "system/$label" 2>/dev/null || true

    if launchctl print "system/$label" >/dev/null 2>&1; then
        launchctl bootout "system/$label" 2>/dev/null || true
        for _ in $(seq 1 50); do   # up to ~5s
            launchctl print "system/$label" >/dev/null 2>&1 || break
            sleep 0.1
        done
    fi

    for _ in $(seq 1 10); do
        if launchctl bootstrap system "$plist" 2>"$errfile"; then
            rm -f "$errfile"
            return 0
        fi
        if launchctl print "system/$label" >/dev/null 2>&1; then
            launchctl kickstart -k "system/$label" 2>/dev/null || true
            rm -f "$errfile"
            return 0
        fi
        sleep 0.3
    done

    echo "error: failed to load daemon after several attempts:" >&2
    cat "$errfile" >&2 2>/dev/null || true
    rm -f "$errfile"
    return 1
}

echo "==> Building release binary…"
# Optimize for size + drop unreachable code (no behavior change).
BUILD_FLAGS="-c release -Xswiftc -Osize -Xlinker -dead_strip"
# Build as the invoking user so SwiftPM caches land in their home, not root's.
if [[ -n "${SUDO_USER:-}" ]]; then
    sudo -u "$SUDO_USER" bash -lc "cd '$REPO_DIR' && swift build $BUILD_FLAGS --product battlify-helper"
else
    (cd "$REPO_DIR" && swift build $BUILD_FLAGS --product battlify-helper)
fi
BIN_SRC="$REPO_DIR/.build/release/battlify-helper"

echo "==> Installing binary to $BIN_DST"
install -d /usr/local/bin
install -m 755 "$BIN_SRC" "$BIN_DST"
# Strip local/debug symbols to shrink the on-disk + resident size.
strip -x "$BIN_DST" || true

echo "==> Installing LaunchDaemon to $PLIST_DST"
install -m 644 "$PLIST_SRC" "$PLIST_DST"
chown root:wheel "$PLIST_DST"

echo "==> Creating config directory"
install -d -m 755 "/Library/Application Support/Battlify"

echo "==> Loading daemon"
if ! reload_daemon "$PLIST_DST" "$LABEL"; then
    exit 1
fi

echo "==> Done. Status:"
sleep 1
"$BIN_DST" status || true
echo
echo "Logs: /var/log/battlify-helper.log"
echo "To uninstall: sudo ./scripts/uninstall-helper.sh"

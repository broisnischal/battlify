#!/bin/bash
# Installs the prebuilt helper from Battlify.app/Contents/Resources. Run as root
# by the app; does not rebuild.
set -euo pipefail

RES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_SRC="$RES_DIR/battlify-helper"
PLIST_SRC="$RES_DIR/com.battlify.helper.plist"
BIN_DST="/usr/local/bin/battlify-helper"
PLIST_DST="/Library/LaunchDaemons/com.battlify.helper.plist"
LABEL="com.battlify.helper"

if [[ "$EUID" -ne 0 ]]; then
    echo "error: must run as root." >&2
    exit 1
fi
if [[ ! -x "$BIN_SRC" ]]; then
    echo "error: bundled helper not found at $BIN_SRC" >&2
    exit 1
fi

# `launchctl bootout` is async: bootstrapping right after it races the old job's
# teardown and fails with "Bootstrap failed: 5". Enable first (a disabled service
# won't bootstrap), wait for the old instance to unload, then bootstrap with retry.
reload_daemon() {
    local plist="$1" label="$2"
    local errfile; errfile="$(mktemp)"

    launchctl enable "system/$label" 2>/dev/null || true

    if launchctl print "system/$label" >/dev/null 2>&1; then
        launchctl bootout "system/$label" 2>/dev/null || true
        for _ in $(seq 1 50); do   # wait up to ~5s for unload
            launchctl print "system/$label" >/dev/null 2>&1 || break
            sleep 0.1
        done
    fi

    for _ in $(seq 1 10); do
        if launchctl bootstrap system "$plist" 2>"$errfile"; then
            rm -f "$errfile"
            return 0
        fi
        # already loaded (we lost the race) — restart onto the new binary and stop
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

install -d /usr/local/bin
install -m 755 "$BIN_SRC" "$BIN_DST"
# strip quarantine, or Gatekeeper kills the LaunchDaemon (build isn't notarized)
xattr -c "$BIN_DST" 2>/dev/null || true

install -m 644 "$PLIST_SRC" "$PLIST_DST"
chown root:wheel "$PLIST_DST"
install -d -m 755 "/Library/Application Support/Battlify"

if ! reload_daemon "$PLIST_DST" "$LABEL"; then
    exit 1
fi

echo "Battlify helper installed and loaded."

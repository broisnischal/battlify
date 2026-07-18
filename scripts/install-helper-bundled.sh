#!/bin/bash
# Installs the Battlify helper daemon from a packaged .app bundle.
# This script lives in Battlify.app/Contents/Resources and copies the prebuilt
# helper next to it — it does NOT rebuild. Invoked by the app with admin rights.
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

# Reload the LaunchDaemon robustly. `launchctl bootout` is asynchronous, so
# bootstrapping straight after it races the old job's teardown and fails with
# "Bootstrap failed: 5: Input/output error" — which, under `set -e`, aborts the
# install and makes the app report failure. This is the common case now that the
# app auto-reinstalls the helper whenever it's out of date. So: enable first (a
# previously disabled service can't bootstrap), wait for the old instance to fully
# unload, then bootstrap with a short retry while the label frees up.
reload_daemon() {
    local plist="$1" label="$2"
    local errfile; errfile="$(mktemp)"

    # A prior `launchctl disable` (or a failed earlier install) would make
    # bootstrap fail until the service is re-enabled.
    launchctl enable "system/$label" 2>/dev/null || true

    # Tear down any running instance and WAIT for it to actually go away.
    if launchctl print "system/$label" >/dev/null 2>&1; then
        launchctl bootout "system/$label" 2>/dev/null || true
        for _ in $(seq 1 50); do   # up to ~5s
            launchctl print "system/$label" >/dev/null 2>&1 || break
            sleep 0.1
        done
    fi

    # Bootstrap, retrying transient failures while the old job finishes unloading.
    for _ in $(seq 1 10); do
        if launchctl bootstrap system "$plist" 2>"$errfile"; then
            rm -f "$errfile"
            return 0
        fi
        # If it ended up loaded anyway (we won the race), make sure it's running
        # the freshly installed binary and call it done.
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
# The DMG isn't notarized yet, so the bundled helper can carry a quarantine flag.
# A quarantined binary run as a LaunchDaemon is killed by Gatekeeper, so strip it
# from the installed copy — otherwise the daemon "installs" but never starts.
xattr -c "$BIN_DST" 2>/dev/null || true

install -m 644 "$PLIST_SRC" "$PLIST_DST"
chown root:wheel "$PLIST_DST"
install -d -m 755 "/Library/Application Support/Battlify"

if ! reload_daemon "$PLIST_DST" "$LABEL"; then
    exit 1
fi

echo "Battlify helper installed and loaded."

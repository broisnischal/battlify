#!/bin/bash
# Runs the Swift test suite (unit tests + benchmarks) via swift-testing.
#
# On machines with only the Command Line Tools (no full Xcode), swift-testing's
# Testing.framework isn't on the default build/runtime search path, so we point the
# build at it and bake the rpaths into the test binary. With full Xcode installed
# (incl. GitHub's macOS CI runners), plain `swift test` already finds it.
#
# Usage: ./scripts/test.sh [extra swift test args, e.g. --filter Caffeine]
set -euo pipefail

DEV="$(xcode-select -p)"
if [[ "$DEV" == *CommandLineTools* ]]; then
    FW="$DEV/Library/Developer/Frameworks"
    LIB="$DEV/Library/Developer/usr/lib"
    echo "==> Command Line Tools detected — adding swift-testing framework paths"
    exec swift test \
        -Xswiftc -F"$FW" \
        -Xlinker -F"$FW" \
        -Xlinker -rpath -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$LIB" "$@"
else
    exec swift test "$@"
fi

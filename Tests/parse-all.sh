#!/usr/bin/env bash
# Syntax-checks every Swift file in the project.
#
# This does NOT type-check the SwiftUI, AVFoundation, CoreMotion or
# WatchConnectivity code — those frameworks don't exist off Apple platforms —
# but it does catch every syntax error, which is most of what goes wrong when
# a file is edited without a compiler to hand.
set -euo pipefail
cd "$(dirname "$0")/.."

SWIFTC="${SWIFTC:-swiftc}"
fail=0
while read -r f; do
    if ! out=$("$SWIFTC" -parse -swift-version 5 "$f" 2>&1) || echo "$out" | grep -q "error:"; then
        echo "=== $f"; echo "$out" | grep "error:" || true; fail=1
    fi
done < <(find Groove -name '*.swift' | sort)

if [ "$fail" -eq 0 ]; then echo "all files parse clean"; else exit 1; fi

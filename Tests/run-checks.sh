#!/usr/bin/env bash
# Logic checks that need no Xcode, no simulator and no device.
#
# Everything under Groove/Shared plus the example-data generator is pure
# Foundation, so it compiles and runs anywhere Swift does — including Linux.
# That covers the parts most likely to break silently: trace alignment, the
# ensemble band, self-labelling separation, JSON round-tripping, and whether
# the first-run example still tells a believable story.
#
#   ./Tests/run-checks.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SWIFTC="${SWIFTC:-swiftc}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

cp Tests/ExampleDataChecks.swift "$OUT/main.swift"
"$SWIFTC" -swift-version 5 -O -o "$OUT/checks" \
    Groove/Shared/Models.swift \
    Groove/Shared/Discipline.swift \
    Groove/Shared/SwingAnalyzer.swift \
    Groove/Shared/Score.swift \
    Groove/Phone/DemoData.swift \
    "$OUT/main.swift"
"$OUT/checks"

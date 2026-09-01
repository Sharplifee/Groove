#!/bin/sh
# Replay a diagnostic capture through the real engine.
#   Tools/replay-capture.sh groove-capture-*.json [--narrate]
set -e
SWIFTC="${SWIFTC:-swiftc}"
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
cp Tools/Replay.swift "$OUT/main.swift"
"$SWIFTC" -O -o "$OUT/replay" \
    Groove/Shared/Models.swift \
    Groove/Shared/Discipline.swift \
    Groove/Shared/SwingAnalyzer.swift \
    Groove/Shared/Score.swift \
    Groove/Shared/RoutineDetector.swift \
    Groove/Shared/Capture.swift \
    Groove/Shared/Narrator.swift \
    "$OUT/main.swift"
"$OUT/replay" "$@"

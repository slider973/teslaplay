#!/bin/sh
# Compile et lance le harnais macOS (Core/ + Tools/Harness/main.swift).
# Usage : Tools/run-harness.sh [port=8099] [secondes=60] [dump.mp4]
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/teslamirror-harness"
xcrun swiftc -O -swift-version 5 -o "$OUT" "$ROOT"/Core/*.swift "$ROOT/Tools/Harness/main.swift"
exec "$OUT" "$@"

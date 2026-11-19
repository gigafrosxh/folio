#!/bin/zsh
# Performance baseline on synthetic libraries (#219). Never touches ~/Documents/Folio.
# Usage: scripts/benchmark.sh [sizes, default 100,1000,10000]   → bench/<date>-<commit>.json/.csv (core) and -app.json (app)
set -euo pipefail
cd "$(dirname "$0")/.."
SIZES="${1:-100,1000,10000}"
COMMIT="$(git rev-parse --short HEAD)$(git diff --quiet || echo '-dirty')"
OUT="bench/$(date +%Y-%m-%d)-$COMMIT"
mkdir -p bench
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swift build -c release --product folio-bench >/dev/null
swift build -c release --product Folio >/dev/null
BIN="$(swift build -c release --show-bin-path)"
"$BIN/folio-bench" "$WORK/core" "$OUT.json" "$SIZES" "$COMMIT"
# App side: main-thread reload, opening notes, typing in long text and code blocks (background, no window, no focus).
mkdir -p "$WORK/app"
FOLIO_LIBRARY="$WORK/app" FOLIO_BACKGROUND=1 FOLIO_BENCH="$OUT-app.json" FOLIO_BENCH_SIZE=1000 FOLIO_BENCH_COMMIT="$COMMIT" \
  "$BIN/Folio" | grep -m 20 -E "^BENCH" | tee /dev/stderr | grep -q "BENCH done"
pkill -f "$BIN/Folio" 2>/dev/null || true
echo "Berichte: $OUT.json, $OUT.csv, $OUT-app.json"

#!/bin/bash
# App-level regression checks. Starts the debug build with a scratch library (FOLIO_LIBRARY) and the
# FOLIO_TYPE scenarios from LayoutDebug, then checks what they print. Usage: scripts/ui-regression.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
swift build --product Folio >/dev/null || exit 1
LIB="$(mktemp -d)"
trap 'rm -rf "$LIB"' EXIT
mkdir -p "$LIB/Test"
FAILED=0


run() {   # run <scenario> <expected substring>
    local scenario="$1" expected="$2"
    rm -rf "$LIB/Test"/* && .build/debug/folio-dump --seed "$LIB/Test/Notiz.folio" >/dev/null
    local out
    out="$(FOLIO_LIBRARY="$LIB" FOLIO_OPEN="$LIB/Test/Notiz.folio" FOLIO_LAYOUT_DUMP=1 FOLIO_DUMP_DELAY=8 \
           FOLIO_TYPE="$scenario" timeout 11 .build/debug/Folio 2>/dev/null | grep "LAYOUT $scenario")"
    if [[ "$out" == *"$expected"* ]]; then
        echo "✓ $scenario"
    else
        echo "✗ $scenario – erwartet: $expected"
        echo "  bekommen: $out"
        FAILED=1
    fi
}

run "delete-test" "geheim\\' is not defined"   # gelöschter Block: Variable weg
run "delete-test2" '"2\nFalse\n"'                             # übrige Blöcke werden wiederhergestellt
run "linked-run" "10"                                         # verknüpfte Blöcke teilen Variablen
exit $FAILED

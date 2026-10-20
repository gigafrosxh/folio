#!/bin/bash
# Writes Tests/FolioCoreTests/Fixtures/note-<version>.folio with the FolioCore of older releases (#69):
# the old types decode the JSON below and the old encoder writes the file, exactly as that app version would.
# Usage: scripts/make-fixtures.sh v0.1.0 v0.12.4 …   (needs the git tags)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
for TAG in "$@"; do
    DIR="$WORK/$TAG"; mkdir -p "$DIR"
    git -C "$ROOT" archive "$TAG" Sources/FolioCore | tar -x -C "$DIR"
    (cd "$DIR" && swiftc -O -suppress-warnings $(find Sources/FolioCore -name '*.swift' ! -name PseudoTerminal.swift) "$ROOT/scripts/fixtures/main.swift" -o gen)
    python3 "$ROOT/scripts/fixtures/write.py" "$TAG" "$DIR" "$ROOT/Tests/FolioCoreTests/Fixtures"
done

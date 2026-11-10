#!/bin/bash
# Macht aus einer fertigen Folio.app eine Testkopie mit eigener Bundle-ID (#136). macOS legt alle Einstellungen,
# auch die Fensterpositionen von AppKit, unter der Bundle-ID ab und beachtet CFFIXED_USER_HOME nicht mehr zuverlässig.
# Nur eine eigene ID hält Testläufe sicher von ~/Library/Preferences/de.daniel.folio.plist fern.
#   scripts/make-test-app.sh <Folio.app> <neuer Zielordner>   – gibt den Pfad der ausführbaren Datei aus
set -euo pipefail

TEST_ID="de.daniel.folio.selftest"
[[ $# -eq 2 && -x "$1/Contents/MacOS/Folio" ]] || { echo "Aufruf: $0 <Folio.app> <neuer Zielordner>" >&2; exit 2; }
[[ ! -e "$2" ]] || { echo "Fehler: $2 existiert schon." >&2; exit 2; }
APP="$2/Folio Test.app"
mkdir -p "$APP"
# Ohne PlugIns: Die Kopie meldet keine Widgets an.
/usr/bin/rsync -a --exclude '/Contents/PlugIns' "$1/" "$APP/"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TEST_ID" "$PLIST"
# Die Kopie übernimmt keine folio://-Links der echten App.
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$PLIST" 2>/dev/null || true
codesign --force --sign - "$APP" >/dev/null 2>&1
# Jeder Lauf beginnt mit leeren Testeinstellungen; die Domain gehört nur der Testkopie.
defaults delete "$TEST_ID" 2>/dev/null || true
printf '%s\n' "$APP/Contents/MacOS/Folio"

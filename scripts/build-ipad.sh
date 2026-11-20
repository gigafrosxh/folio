#!/bin/zsh
# Builds Folio for iPad (#214) for the iOS Simulator and packs build/FolioPad.app.
# Usage: scripts/build-ipad.sh            → build only
#        scripts/build-ipad.sh <udid>     → also install and launch in that (booted) simulator
# CONFIG=Release scripts/build-ipad.sh    → Release instead of Debug (#341); the CI builds both (#316).
# There is no Apple developer account yet: device builds and distribution are not possible (see #213).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-Debug}"
[[ "$CONFIG" == Debug || "$CONFIG" == Release ]] || { echo "CONFIG muss Debug oder Release sein" >&2; exit 2; }
DD=.build/ipad
xcodebuild -scheme FolioPad -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" \
  -configuration "$CONFIG" -quiet build
BIN="$DD/Build/Products/$CONFIG-iphonesimulator/FolioPad"
APP=build/FolioPad.app
rm -rf "$APP"
mkdir -p "$APP"
cp "$BIN" "$APP/FolioPad"
cp Resources/Pad/Info.plist "$APP/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Info.plist"
# Package resources (FolioCore bundles, if any) next to the binary.
for b in "$DD"/Build/Products/$CONFIG-iphonesimulator/*.bundle(N); do cp -R "$b" "$APP/"; done
codesign --force --sign - "$APP" >/dev/null
echo "$APP"
if [[ $# -ge 1 ]]; then
  xcrun simctl install "$1" "$APP"
  xcrun simctl launch "$1" de.daniel.folio.pad
fi

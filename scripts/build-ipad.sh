#!/bin/zsh
# Builds Folio for iPad (#214) for the iOS Simulator and packs build/FolioPad.app.
# Usage: scripts/build-ipad.sh            → build only
#        scripts/build-ipad.sh <udid>     → also install and launch in that (booted) simulator
# There is no Apple developer account yet: device builds and distribution are not possible (see #213).
set -euo pipefail
cd "$(dirname "$0")/.."
DD=.build/ipad
xcodebuild -scheme FolioPad -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" \
  -configuration Debug -quiet build
BIN="$DD/Build/Products/Debug-iphonesimulator/FolioPad"
APP=build/FolioPad.app
rm -rf "$APP"
mkdir -p "$APP"
cp "$BIN" "$APP/FolioPad"
cp Resources/Pad/Info.plist "$APP/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Info.plist"
# Package resources (FolioCore bundles, if any) next to the binary.
for b in "$DD"/Build/Products/Debug-iphonesimulator/*.bundle(N); do cp -R "$b" "$APP/"; done
codesign --force --sign - "$APP" >/dev/null
echo "$APP"
if [[ $# -ge 1 ]]; then
  xcrun simctl install "$1" "$APP"
  xcrun simctl launch "$1" de.daniel.folio.pad
fi

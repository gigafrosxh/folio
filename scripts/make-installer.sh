#!/bin/bash
# Builds Folio for Apple Silicon (arm64, release) and packages it as
#   dist/Folio-<version>-arm64.dmg  – drag-to-Applications disk image
#   dist/Folio-<version>-arm64.pkg  – installer that puts Folio into /Applications
# Signing: SIGN_IDENTITY="Developer ID Application: …" signs with that identity; default is ad-hoc ("-").
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
IDENTITY="${SIGN_IDENTITY:--}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DIST="$ROOT/dist"
STAGE="$ROOT/build/dmg-stage"
NAME="Folio-$VERSION-arm64"

CONFIG=release ARCH=arm64 scripts/build-app.sh >/dev/null
APP="$ROOT/build/Folio.app"
if [[ "$IDENTITY" != "-" ]]; then
    codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
fi
lipo -archs "$APP/Contents/MacOS/Folio" | grep -q arm64

rm -rf "$STAGE" && mkdir -p "$STAGE/.background" "$DIST"
/usr/bin/ditto "$APP" "$STAGE/Folio.app"
ln -s /Applications "$STAGE/Programme"
swift scripts/make-dmg-background.swift "$STAGE/.background/background.png"

# Writable image first, so Finder can store the window layout, then convert to compressed read-only.
RW="$ROOT/build/$NAME-rw.dmg"
rm -f "$RW" "$DIST/$NAME.dmg"
hdiutil create -quiet -volname "Folio" -srcfolder "$STAGE" -fs APFS -format UDRW "$RW"
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')"
osascript <<APPLESCRIPT || echo "Hinweis: Fensterlayout konnte nicht gesetzt werden (Finder-Automation nicht erlaubt) – DMG funktioniert trotzdem."
tell application "Finder"
    tell disk "Folio"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 840, 520}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set background picture of viewOptions to file ".background:background.png"
        set position of item "Folio.app" of container window to {170, 200}
        set position of item "Programme" of container window to {470, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
sync
hdiutil detach -quiet "$MOUNT" || hdiutil detach -force -quiet "$MOUNT"
hdiutil convert -quiet "$RW" -format ULFO -o "$DIST/$NAME.dmg"
rm -f "$RW"
codesign --force --sign "$IDENTITY" "$DIST/$NAME.dmg" 2>/dev/null || true

# Component package installing into /Applications.
PKGROOT="$ROOT/build/pkg-root"
rm -rf "$PKGROOT" && mkdir -p "$PKGROOT/Applications"
/usr/bin/ditto "$APP" "$PKGROOT/Applications/Folio.app"
pkgbuild --quiet --root "$PKGROOT" --identifier de.daniel.folio.pkg --version "$VERSION" \
    --install-location / "$DIST/$NAME.pkg"
rm -rf "$PKGROOT" "$STAGE"

echo "$DIST/$NAME.dmg"
echo "$DIST/$NAME.pkg"

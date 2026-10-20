#!/bin/bash
# Builds Folio for Apple Silicon (arm64, release) and packages it as
#   dist/Folio-<version>-arm64.dmg  – drag-to-Applications disk image
#   dist/Folio-<version>-arm64.pkg  – installer that puts Folio into /Applications
# Signing and notarization (#63, see docs/SIGNING.md):
#   SIGN_IDENTITY       "Developer ID Application: …"; "auto" (default) takes the one in the keychain if there is
#                       one, otherwise the app is signed ad hoc ("-").
#   INSTALLER_IDENTITY  "Developer ID Installer: …"; "auto" (default) likewise, for the .pkg.
#   NOTARY_PROFILE      keychain profile from `xcrun notarytool store-credentials` (default "folio-notary"); when it
#                       exists and the app is Developer-ID-signed, DMG and PKG are notarized and stapled.
# The last output line is "SIGNED=developer-id|adhoc NOTARIZED=yes|no".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
first_identity() { security find-identity -v $2 2>/dev/null | grep -o "\"$1: [^\"]*\"" | head -1 | tr -d '"' || true; }
IDENTITY="${SIGN_IDENTITY:-auto}"
[[ "$IDENTITY" == auto ]] && IDENTITY="$(first_identity "Developer ID Application" "-p codesigning")"
[[ -z "$IDENTITY" ]] && IDENTITY="-"
INSTALLER="${INSTALLER_IDENTITY:-auto}"
[[ "$INSTALLER" == auto ]] && INSTALLER="$(first_identity "Developer ID Installer" "")"
PROFILE="${NOTARY_PROFILE:-folio-notary}"
ENTITLEMENTS="$ROOT/Resources/Folio.entitlements"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DIST="$ROOT/dist"
STAGE="$ROOT/build/dmg-stage"
NAME="Folio-$VERSION-arm64"

CONFIG=release ARCH=arm64 scripts/build-app.sh >/dev/null
APP="$ROOT/build/Folio.app"
if [[ "$IDENTITY" != "-" ]]; then
    # Hardened runtime, secure timestamp and only the entitlements Folio needs.
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
    codesign --verify --strict --deep "$APP"
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
if [[ "$IDENTITY" != "-" ]]; then codesign --force --timestamp --sign "$IDENTITY" "$DIST/$NAME.dmg"; fi

# Component package installing into /Applications.
PKGROOT="$ROOT/build/pkg-root"
rm -rf "$PKGROOT" && mkdir -p "$PKGROOT/Applications"
/usr/bin/ditto "$APP" "$PKGROOT/Applications/Folio.app"
PKGSIGN=()
[[ -n "$INSTALLER" && "$IDENTITY" != "-" ]] && PKGSIGN=(--sign "$INSTALLER" --timestamp)
pkgbuild --quiet --root "$PKGROOT" --identifier de.daniel.folio.pkg --version "$VERSION" \
    --install-location / ${PKGSIGN[@]+"${PKGSIGN[@]}"} "$DIST/$NAME.pkg"
rm -rf "$PKGROOT" "$STAGE"

# Notarization: Apple scans the signed files and issues a ticket; stapling it lets Gatekeeper accept
# Folio on first launch, even offline. An unsigned .pkg cannot be notarized, so only the DMG is sent then.
NOTARIZED=no
if [[ "$IDENTITY" != "-" ]] && xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    NOTARIZED=yes
    FILES=("$DIST/$NAME.dmg")
    [[ ${#PKGSIGN[@]} -gt 0 ]] && FILES+=("$DIST/$NAME.pkg")
    for FILE in "${FILES[@]}"; do
        if xcrun notarytool submit "$FILE" --keychain-profile "$PROFILE" --wait --timeout 30m >&2 \
           && xcrun stapler staple "$FILE" >&2; then
            spctl --assess --type open --context context:primary-signature -v "$FILE" >&2 || NOTARIZED=no
        else
            NOTARIZED=no
            echo "Notarisierung von $(basename "$FILE") fehlgeschlagen – Details: xcrun notarytool log <id> --keychain-profile $PROFILE" >&2
        fi
    done
elif [[ "$IDENTITY" != "-" ]]; then
    echo "Hinweis: Kein notarytool-Profil „$PROFILE“ – signiert, aber nicht notarisiert (docs/SIGNING.md)." >&2
else
    echo "Hinweis: Kein „Developer ID Application“-Zertifikat – ad hoc signiert, nicht notarisiert (docs/SIGNING.md)." >&2
fi

echo "$DIST/$NAME.dmg"
echo "$DIST/$NAME.pkg"
echo "SIGNED=$([[ "$IDENTITY" == "-" ]] && echo adhoc || echo developer-id) NOTARIZED=$NOTARIZED"

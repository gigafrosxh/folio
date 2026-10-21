#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
INSTALL=false
RUN=false
for argument in "$@"; do
    case "$argument" in
        --install) INSTALL=true ;;
        --run) RUN=true ;;
        --help|-h)
            printf 'Verwendung: %s [--install] [--run]\nCONFIG=debug wählt einen Debug-Build (Standard: release).\n' "$0"
            exit 0 ;;
        *) printf 'Unbekannte Option: %s\n' "$argument" >&2; exit 2 ;;
    esac
done
case "$CONFIG" in
    debug|release) ;;
    *) printf 'CONFIG muss debug oder release sein.\n' >&2; exit 2 ;;
esac

cd "$ROOT"
ARCH_ARGS=()
if [[ -n "${ARCH:-}" ]]; then ARCH_ARGS=(--arch "$ARCH"); fi
swift build -c "$CONFIG" --product Folio ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
swift build -c "$CONFIG" --product FolioWidgets ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)"
if [[ ! -f Resources/AppIcon.icns ]]; then
    swift scripts/make-icon.swift Resources
fi
/usr/bin/plutil -lint Resources/Info.plist

APP="$ROOT/build/Folio.app"
mkdir -p "$ROOT/build"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Folio" "$APP/Contents/MacOS/Folio"
chmod +x "$APP/Contents/MacOS/Folio"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# KaTeX, Mermaid and the page that renders formulas and diagrams offline.
/usr/bin/ditto Resources/Web "$APP/Contents/Resources/Web"
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
    /usr/bin/ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
# Desktop widgets (#78–#84) as a WidgetKit extension; sandboxed, signed before the app.
APPEX="$APP/Contents/PlugIns/FolioWidgets.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp "$BIN_DIR/FolioWidgets" "$APPEX/Contents/MacOS/FolioWidgets"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
sed -e "s/VERSION/$VERSION/" -e "s/BUILD/$BUILD/" Resources/Widgets/Info.plist >"$APPEX/Contents/Info.plist"
/usr/bin/plutil -lint "$APPEX/Contents/Info.plist" >/dev/null
codesign --force --sign - --entitlements Resources/Widgets/FolioWidgets.entitlements "$APPEX"
codesign --force --sign - "$APP"

if "$INSTALL"; then
    mkdir -p "$HOME/Applications"
    DESTINATION="$HOME/Applications/Folio.app"
    rm -rf "$DESTINATION"
    /usr/bin/ditto "$APP" "$DESTINATION"
    APP="$DESTINATION"
fi
printf '%s\n' "$APP"
if "$RUN"; then
    open "$APP"
fi

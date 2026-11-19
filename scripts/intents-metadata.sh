#!/bin/zsh
# Generates Metadata.appintents without an Xcode project: the Swift compiler gathers the App Intents constants of a
# module, Apple's metadata processor turns them into the bundle the system reads (widgets #122, Shortcuts #70).
# Usage: scripts/intents-metadata.sh <bin-dir> <output Resources folder> [module] [swift version] [expected type]
#   scripts/intents-metadata.sh "$BIN_DIR" "$APPEX/Contents/Resources"                      # widget extension
#   scripts/intents-metadata.sh "$BIN_DIR" "$APP/Contents/Resources" Folio 5 CreateNoteIntent  # the app
set -euo pipefail
cd "$(dirname "$0")/.."
BIN_DIR="$1"; OUT="$2"; MODULE="${3:-FolioWidgets}"; SWIFT_VERSION="${4:-6}"; EXPECT="${5:-PickNoteIntent}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SDK="$(xcrun --show-sdk-path --sdk macosx)"
TOOLCHAIN="$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")"
TARGET="arm64-apple-macos15.2"
SRCS=("$PWD"/Sources/"$MODULE"/**/*.swift)
cat > "$WORK/protocols.json" <<'JSON'
["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","WidgetConfigurationIntent","EntityStringQuery","EntityPropertyQuery","IntentValueQuery"]
JSON
# SwiftPM's own build system puts modules into <bin>/Modules, the swift-build based one next to the products (#266).
MODULE_DIR="$(dirname "$(find "$BIN_DIR" -maxdepth 2 -name FolioWidgetData.swiftmodule -print -quit)")"
[[ -n "$MODULE_DIR" && "$MODULE_DIR" != "." ]] || { echo "Module nicht in $BIN_DIR gefunden" >&2; exit 1; }
# The C target FolioTerminal, for modules that import FolioCore.
cat > "$WORK/FolioTerminal.modulemap" <<MAP
module FolioTerminal {
  umbrella header "$PWD/Sources/FolioTerminal/include/FolioTerminal.h"
  export *
}
MAP
xcrun swiftc -parse-as-library -module-name "$MODULE" -target "$TARGET" -sdk "$SDK" -I "$MODULE_DIR" -swift-version "$SWIFT_VERSION" \
  -Xcc -fmodule-map-file="$WORK/FolioTerminal.modulemap" -Onone \
  -wmo -c "${SRCS[@]}" -o "$WORK/module.o" \
  -Xfrontend -const-gather-protocols-file -Xfrontend "$WORK/protocols.json" -emit-const-values-path "$WORK/module.swiftconstvalues" \
  2> "$WORK/compile.log" || { grep -E "error:" "$WORK/compile.log" | head -20 >&2; exit 1; }
printf '%s\n' "${SRCS[@]}" > "$WORK/sources.txt"
echo "$WORK/module.swiftconstvalues" > "$WORK/constvalues.txt"
XCODE_BUILD="$(xcodebuild -version | awk '/Build version/ {print $3}')"
xcrun appintentsmetadataprocessor --output "$WORK/out" --toolchain-dir "$TOOLCHAIN" --module-name "$MODULE" \
  --sdk-root "$SDK" --xcode-version "$XCODE_BUILD" --platform-family macOS --deployment-target 15.2 --target-triple "$TARGET" \
  --source-file-list "$WORK/sources.txt" --swift-const-vals-list "$WORK/constvalues.txt" >/dev/null 2>"$WORK/log" || { cat "$WORK/log" >&2; exit 1; }
grep -q "$EXPECT" "$WORK/out/Metadata.appintents/extract.actionsdata" || { echo "Metadata.appintents ohne $EXPECT" >&2; exit 1; }
mkdir -p "$OUT"
rm -rf "$OUT/Metadata.appintents"
/usr/bin/ditto "$WORK/out/Metadata.appintents" "$OUT/Metadata.appintents"

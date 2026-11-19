#!/bin/zsh
# Generates Metadata.appintents for the widget extension (#122) without an Xcode project:
# the Swift compiler gathers the App Intents constants, Apple's metadata processor turns them into the bundle
# WidgetKit reads for „Widget bearbeiten“.
# Usage: scripts/widget-intents-metadata.sh <bin-dir with FolioWidgetData.swiftmodule> <output Resources folder>
set -euo pipefail
cd "$(dirname "$0")/.."
BIN_DIR="$1"; OUT="$2"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SDK="$(xcrun --show-sdk-path --sdk macosx)"
TOOLCHAIN="$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")"
TARGET="arm64-apple-macos15.2"
SRCS=("$PWD"/Sources/FolioWidgets/*.swift)
cat > "$WORK/protocols.json" <<'JSON'
["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","WidgetConfigurationIntent","EntityStringQuery","EntityPropertyQuery","IntentValueQuery"]
JSON
xcrun swiftc -parse-as-library -module-name FolioWidgets -target "$TARGET" -sdk "$SDK" -I "$BIN_DIR" -swift-version 6 \
  -wmo -c "${SRCS[@]}" -o "$WORK/intents.o" \
  -Xfrontend -const-gather-protocols-file -Xfrontend "$WORK/protocols.json" -emit-const-values-path "$WORK/intents.swiftconstvalues"
printf '%s\n' "${SRCS[@]}" > "$WORK/sources.txt"
echo "$WORK/intents.swiftconstvalues" > "$WORK/constvalues.txt"
XCODE_BUILD="$(xcodebuild -version | awk '/Build version/ {print $3}')"
xcrun appintentsmetadataprocessor --output "$WORK/out" --toolchain-dir "$TOOLCHAIN" --module-name FolioWidgets \
  --sdk-root "$SDK" --xcode-version "$XCODE_BUILD" --platform-family macOS --deployment-target 15.2 --target-triple "$TARGET" \
  --source-file-list "$WORK/sources.txt" --swift-const-vals-list "$WORK/constvalues.txt" >/dev/null 2>"$WORK/log" || { cat "$WORK/log" >&2; exit 1; }
grep -q "PickNoteIntent" "$WORK/out/Metadata.appintents/extract.actionsdata" || { echo "Metadata.appintents ohne PickNoteIntent" >&2; exit 1; }
mkdir -p "$OUT"
rm -rf "$OUT/Metadata.appintents"
/usr/bin/ditto "$WORK/out/Metadata.appintents" "$OUT/Metadata.appintents"

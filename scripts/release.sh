#!/bin/bash
# Veröffentlicht eine neue Folio-Version auf GitHub.
#   scripts/release.sh patch|minor|major   – Version aus Resources/Info.plist hochzählen
#   scripts/release.sh 1.2.3               – genau diese Version
# Ablauf: Info.plist (CFBundleShortVersionString + CFBundleVersion) und CHANGELOG.md
# ([Unreleased] → [X.Y.Z]) aktualisieren, committen, Tag vX.Y.Z setzen, DMG/PKG mit
# scripts/make-installer.sh bauen, pushen und ein GitHub-Release mit beiden Dateien anlegen.
# Ist die Version schon in Info.plist und CHANGELOG eingetragen, wird nichts hochgezählt.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PLIST=Resources/Info.plist
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
die() { echo "Fehler: $*" >&2; exit 1; }
# Inhalt des CHANGELOG-Abschnitts "## [$1]" ohne Überschrift
section() { awk -v h="## [$1]" 'index($0, h) == 1 { on = 1; next } /^## \[/ { on = 0 } on' CHANGELOG.md; }

[[ $# -eq 1 ]] || die "Aufruf: $0 patch|minor|major|X.Y.Z"
command -v gh >/dev/null || die "gh fehlt (brew install gh)"
gh auth status >/dev/null 2>&1 || die "gh ist nicht angemeldet (gh auth login)"
[[ -z "$(git status --porcelain)" ]] || die "Arbeitskopie hat uncommittete Änderungen – erst committen."
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "Releases nur von main."
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "main ist nicht auf dem Stand von origin/main."

CURRENT="$(pb 'Print :CFBundleShortVersionString')"
IFS=. read -r MA MI PA <<<"$CURRENT"
case "$1" in
    major) VERSION="$((MA + 1)).0.0" ;;
    minor) VERSION="$MA.$((MI + 1)).0" ;;
    patch) VERSION="$MA.$MI.$((PA + 1))" ;;
    *)     VERSION="$1" ;;
esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Ungültige Version: $VERSION"
TAG="v$VERSION"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "Tag $TAG existiert schon."

if [[ "$VERSION" != "$CURRENT" ]]; then
    BUILD="$(pb 'Print :CFBundleVersion')"
    pb "Set :CFBundleShortVersionString $VERSION"
    pb "Set :CFBundleVersion $((BUILD + 1))"
fi
if ! grep -q "^## \[$VERSION\]" CHANGELOG.md; then
    section Unreleased | grep -q '[^[:space:]]' || die "CHANGELOG.md: unter [Unreleased] steht nichts."
    sed -i '' "s/^## \[Unreleased\]\$/## [Unreleased]\\
\\
## [$VERSION] – $(date +%F)/" CHANGELOG.md
fi
if [[ -n "$(git status --porcelain)" ]]; then
    git commit -q -m "Version $VERSION" -- "$PLIST" CHANGELOG.md
fi
git tag -a "$TAG" -m "Folio $VERSION"

echo "Baue Installer für $VERSION …"
OUT="$(scripts/make-installer.sh)"
DMG="$(grep '\.dmg$' <<<"$OUT")"
PKG="$(grep '\.pkg$' <<<"$OUT")"

NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
section "$VERSION" >"$NOTES"
cat >>"$NOTES" <<'EOF'

---
**Installation:** `Folio-…-arm64.dmg` öffnen und Folio auf „Programme“ ziehen, oder das `.pkg` ausführen. Nur für Macs mit Apple Silicon, macOS 15.2 oder neuer.
Folio ist nicht notarisiert. Beim ersten Start meldet macOS deshalb, dass die App nicht überprüft werden kann: in **Systemeinstellungen → Datenschutz & Sicherheit** auf „Trotzdem öffnen“ klicken, oder im Terminal `xattr -dr com.apple.quarantine /Applications/Folio.app` ausführen.
EOF

git push -q origin main "$TAG"
gh release create "$TAG" "$DMG" "$PKG" --title "Folio $VERSION" --notes-file "$NOTES" --verify-tag

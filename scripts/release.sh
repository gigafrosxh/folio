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
[[ -z "$(git status --porcelain -- "$PLIST" CHANGELOG.md)" ]] || die "$PLIST oder CHANGELOG.md hat uncommittete Änderungen."
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "Releases nur von main."
git fetch -q origin main
git merge-base --is-ancestor origin/main HEAD || die "main liegt hinter origin/main zurück – erst pullen."

CURRENT="$(pb 'Print :CFBundleShortVersionString')"
IFS=. read -r MA MI PA <<<"${CURRENT%%-*}"
case "$1" in
    major) VERSION="$((MA + 1)).0.0" ;;
    minor) VERSION="$MA.$((MI + 1)).0" ;;
    patch) VERSION="$MA.$MI.$((PA + 1))" ;;
    *)     VERSION="$1" ;;
esac
# X.Y.Z or a SemVer pre-release such as 1.0.0-rc.1 (the update check orders those correctly).
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$ ]] || die "Ungültige Version: $VERSION"
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
if [[ -n "$(git status --porcelain -- "$PLIST" CHANGELOG.md)" ]]; then
    git commit -q -m "Version $VERSION" -- "$PLIST" CHANGELOG.md
fi
git tag -a "$TAG" -m "Folio $VERSION"

# Gebaut wird aus einem Export des Tags, nicht aus der Arbeitskopie: uncommittete Änderungen landen nie im Release.
WORK="$(mktemp -d)"
NOTES="$WORK/notes.md"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/src" && git archive "$TAG" | tar -x -C "$WORK/src"
echo "Baue Installer für $VERSION …"
OUT="$("$WORK/src/scripts/make-installer.sh")"
tail -1 <<<"$OUT"
mkdir -p dist
cp "$(grep '\.dmg$' <<<"$OUT")" "$(grep '\.pkg$' <<<"$OUT")" dist/
DMG="dist/Folio-$VERSION-arm64.dmg"
PKG="dist/Folio-$VERSION-arm64.pkg"
section "$VERSION" >"$NOTES"
cat >>"$NOTES" <<'EOF'

---
**Installation:** `Folio-…-arm64.dmg` öffnen und Folio auf „Programme“ ziehen, oder das `.pkg` ausführen. Nur für Macs mit Apple Silicon, macOS 15.2 oder neuer.
EOF
if grep -q "NOTARIZED=yes" <<<"$OUT"; then
    echo "Folio ist mit einer Developer ID signiert und von Apple notarisiert." >>"$NOTES"
else
    cat >>"$NOTES" <<'EOF'
Folio ist nicht notarisiert. Beim ersten Start meldet macOS deshalb, dass die App nicht überprüft werden kann: in **Systemeinstellungen → Datenschutz & Sicherheit** auf „Trotzdem öffnen“ klicken, oder im Terminal `xattr -dr com.apple.quarantine /Applications/Folio.app` ausführen.
EOF
fi
echo "Datenschutz und Sicherheit: [docs/PRIVACY.md](https://github.com/gigafrosxh/folio/blob/$TAG/docs/PRIVACY.md)" >>"$NOTES"

git push -q origin main "$TAG"
gh release create "$TAG" "$DMG" "$PKG" --title "Folio $VERSION" --notes-file "$NOTES" --verify-tag

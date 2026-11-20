#!/bin/bash
# Veröffentlicht eine neue Folio-Version auf GitHub.
#   scripts/release.sh patch|minor|major   – Version aus Resources/Info.plist hochzählen
#   scripts/release.sh 1.2.3               – genau diese Version
#   scripts/release.sh --check             – nur die Prüfungen auf dem committeten Stand (kein Release)
# Ablauf: Info.plist (CFBundleShortVersionString + CFBundleVersion) und CHANGELOG.md
# ([Unreleased] → [X.Y.Z]) aktualisieren und committen; den Commit exportieren und dort Tests und
# Komplexitätsprüfung ausführen (#315); DMG/PKG aus demselben Export bauen; erst dann Tag vX.Y.Z,
# pushen und ein GitHub-Release mit beiden Dateien anlegen.
# Wiederaufnahme (#319): Scheitert ein Lauf nach dem Versions-Commit, setzt derselbe Aufruf dort fort –
# ein vorhandener Tag auf diesem Commit und ein schon angelegtes Release werden weiterverwendet,
# fehlende Dateien werden hochgeladen. Ist die Version schon eingetragen, wird nichts hochgezählt.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PLIST=Resources/Info.plist
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
die() { echo "Fehler: $*" >&2; exit 1; }
# Inhalt des CHANGELOG-Abschnitts "## [$1]" ohne Überschrift
section() { awk -v h="## [$1]" 'index($0, h) == 1 { on = 1; next } /^## \[/ { on = 0 } on' CHANGELOG.md; }

[[ $# -eq 1 ]] || die "Aufruf: $0 patch|minor|major|X.Y.Z|--check"

# Everything temporary lives in one folder that is removed at the end; the test log is kept only when something
# failed, and its path is printed (#323).
WORK="$(mktemp -d -t folio-release)"
CHECK_LOG="$WORK/tests.log"
KEEP_LOG=""
cleanup() {
    if [[ -n "$KEEP_LOG" && -f "$CHECK_LOG" ]]; then
        cp "$CHECK_LOG" "$KEEP_LOG"
        echo "Testlog: $KEEP_LOG" >&2
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
fail_checks() {
    KEEP_LOG="$(mktemp -t folio-release-tests)"
    die "$1"
}

# Tests and the complexity check run on an export of the commit that is released, never on the working copy:
# uncommitted changes can neither turn them green nor red (#315). The installer is built from the same export.
check_commit() {
    local rev="$1"
    rm -rf "$WORK/src" && mkdir "$WORK/src"
    git archive "$rev" | tar -x -C "$WORK/src"
    echo "Prüfe $(git rev-parse --short "$rev"): Unit-Tests (im Export) …"
    (cd "$WORK/src" && FOLIO_LIBRARY="$WORK/testlib" swift test) >"$CHECK_LOG" 2>&1 \
        || fail_checks "Unit-Tests sind rot, kein Release."
    echo "Prüfe $(git rev-parse --short "$rev"): Komplexität …"
    (cd "$WORK/src" && swift run -c release --package-path Tools/ComplexityCheck complexity-check \
        --baseline Tools/ComplexityCheck/baseline.json Sources) >>"$CHECK_LOG" 2>&1 \
        || fail_checks "Die Komplexitätsprüfung schlägt fehl, kein Release."
}

if [[ "$1" == "--check" ]]; then
    mkdir -p "$WORK/testlib"
    check_commit HEAD
    echo "Prüfungen bestanden (Stand $(git rev-parse --short HEAD), Arbeitskopie nicht berücksichtigt)."
    exit 0
fi

command -v gh >/dev/null || die "gh fehlt (brew install gh)"
gh auth status >/dev/null 2>&1 || die "gh ist nicht angemeldet (gh auth login)"
[[ -z "$(git status --porcelain -- "$PLIST" CHANGELOG.md)" ]] || die "$PLIST oder CHANGELOG.md hat uncommittete Änderungen."
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "Releases nur von main."
git fetch -q origin main --tags
git merge-base --is-ancestor origin/main HEAD || die "main liegt hinter origin/main zurück – erst pullen."

CURRENT="$(pb 'Print :CFBundleShortVersionString')"
IFS=. read -r MA MI PA <<<"${CURRENT%%-*}"
case "$1" in
    major) VERSION="$((MA + 1)).0.0" ;;
    minor) VERSION="$MA.$((MI + 1)).0" ;;
    patch) VERSION="$MA.$MI.$((PA + 1))" ;;
    *)     VERSION="$1" ;;
esac
# Resuming (#319): the last commit is already "Version CURRENT" and that version has no finished release yet.
if [[ "$1" =~ ^(major|minor|patch)$ && "$(git log -1 --format=%s)" == "Version $CURRENT" ]] \
    && ! gh release view "v$CURRENT" --json assets -q '.assets[].name' 2>/dev/null | grep -q '\.pkg$'; then
    echo "Setze das unterbrochene Release $CURRENT fort."
    VERSION="$CURRENT"
fi
# X.Y.Z or a SemVer pre-release such as 1.0.0-rc.1 (the update check orders those correctly).
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$ ]] || die "Ungültige Version: $VERSION"
TAG="v$VERSION"
# A tag that already exists is only fine on the commit being released (an interrupted run, #319).
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    [[ "$(git rev-parse "$TAG^{commit}")" == "$(git rev-parse HEAD)" ]] || die "Tag $TAG existiert schon auf einem anderen Stand."
fi

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

# Rote Tests blockieren jedes Release (#161), geprüft wird genau der Stand, der veröffentlicht wird (#315).
mkdir -p "$WORK/testlib"
check_commit HEAD
NOTES="$WORK/notes.md"
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

# The tag only now, after tests and installer: a failure before this point leaves nothing to clean up (#319).
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "Folio $VERSION"
git push -q origin main "$TAG"
if gh release view "$TAG" >/dev/null 2>&1; then
    # Created by an earlier, interrupted run: upload (or replace) the files (#319).
    gh release upload "$TAG" "$DMG" "$PKG" --clobber
else
    gh release create "$TAG" "$DMG" "$PKG" --title "Folio $VERSION" --notes-file "$NOTES" --verify-tag
fi

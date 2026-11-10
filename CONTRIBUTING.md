# Mitwirken an Folio

Danke fürs Mitmachen! Folio ist eine macOS-Notizen-App in Swift (SwiftUI und AppKit) für macOS 15.2 oder neuer auf Apple Silicon.
Die Oberfläche und die Dokumentation sind deutsch; Code und Kommentare sind englisch.

## Einrichten

1. Xcode 26 oder neuer installieren (Swift 6), dann das Repository klonen.
2. Bauen und testen:

   ```sh
   make build      # swift build
   make test       # Unit-Tests mit einer leeren Testbibliothek
   make app        # build/Folio.app
   ```

3. Die App mit einer **Testbibliothek** starten, nie mit deinen echten Notizen:

   ```sh
   mkdir -p /tmp/folio-test && FOLIO_LIBRARY=/tmp/folio-test .build/debug/Folio
   ```

   Ein Release-Build oder eine App aus dem DMG startet mit `FOLIO_LIBRARY` nur als Testkopie mit eigener Bundle-ID, damit
   deine echten Einstellungen unberührt bleiben: `scripts/make-test-app.sh <Folio.app> <neuer Ordner>` (siehe `AGENTS.md`).

## Architektur

Jede Notiz ist eine eigene komprimierte `.folio`-Datei in einem normalen Ordnerbaum; es gibt keine Datenbank.

| Bereich | Wo | Was |
| --- | --- | --- |
| Kern | `Sources/FolioCore` | Ohne UI und voll getestet: Dateiformat (`FolioArchive`, `NoteFile`), Diagnose, Backups, Versionen, Suche und Filter, Links und Graph-Layout, Markdown-Struktur, Syntax-Hervorhebung, Codeausführung und Kernels, Datenbank-Clients, KI-Kontext. |
| App | `Sources/Folio` | SwiftUI/AppKit: `NoteStore` (Bibliothek, Tabs, Fenster), `NoteDocument`/`BlockModel` (Editor-Modell), Editor, Code-Blöcke, eingebettete Inhalte, Einstellungen, Selbsttests. |
| Widgets | `Sources/FolioWidgetData`, `Sources/FolioWidgetUI`, `Sources/FolioWidgets` | Snapshot-Modell, Ansichten und WidgetKit-Erweiterung. |
| Werkzeuge | `Sources/folio-dump`, `Tools/ComplexityCheck`, `scripts/` | Notizen untersuchen, Komplexität messen, App bauen und veröffentlichen. |

Faustregeln:

- Logik gehört in `FolioCore`, mit Unit-Tests. Die App ruft sie nur auf.
- Neue Felder im Dateiformat immer optional dekodieren (`decodeIfPresent`), damit ältere Notizen lesbar bleiben.
- Beschädigte Notizen werden nie gelöscht, nur nach `.folio/damaged` verschoben.
- In Ansichten nie `NoteDocument.makeFile()` aufrufen (ändert `meta` und erzeugt eine Endlosschleife), sondern `makeFilePreview()`.

## Tests

- `make test` muss grün sein. Neue Logik bekommt Tests in `Tests/FolioCoreTests` oder `Tests/FolioAppTests`.
- Vergleichsdateien in `Tests/FolioCoreTests/Fixtures` (Syntax-Tokens, Graph-Layout, Diagnosen, Parser) schreibt
  `FOLIO_WRITE_GOLDEN=1 swift test` neu, nur wenn sich das Verhalten absichtlich ändert.
- App-Selbsttests ohne Fenster und ohne Fokus: `make build && FOLIO_BACKGROUND=1 python3 scripts/dev-regression.py`.
- Die Komplexitätsprüfung (`docs/COMPLEXITY.md`) läuft im CI; keine Funktion darf neu über 15 Punkte kommen.

## Issues und Pull Requests

- Fehler und Wünsche als Issue mit den Vorlagen melden. Jedes Issue bekommt eine Priorität von `P0` (Datenverlust, Absturz,
  Eingabe am falschen Ort) bis `P3`.
- Ein Pull Request löst ein Issue (`Closes #N`), trägt einen Eintrag unter `## [Unreleased]` in `CHANGELOG.md` ein und
  beschreibt, wie er getestet wurde.
- Commit-Titel auf Deutsch, kurz und im Stil des Repos („Wortzähler zeigt „1 Wort“ statt „1 Wörter““).
- Datenschutz: Neue Netzwerkzugriffe oder Speicherorte in `docs/PRIVACY.md` nachtragen.

Releases macht der Maintainer mit `make release V=patch|minor|major` (siehe README).

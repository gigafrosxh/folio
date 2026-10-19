# Changelog

Alle nennenswerten Änderungen an Folio stehen in dieser Datei.
Das Format folgt [Keep a Changelog](https://keepachangelog.com/de/1.1.0/), die Versionsnummern folgen [Semantic Versioning](https://semver.org/lang/de/).

Neue Einträge kommen unter **Unreleased**; `scripts/release.sh` macht daraus beim Release den Abschnitt der neuen Version.

## [Unreleased]

## [0.4.0] – 2026-10-19

### Hinzugefügt
- IDE-Autovervollständigung in Codefeldern: Vorschlagsliste mit Methoden, Feldern, Klassen und Modulen nach `.`, `::`, `->`, ab zwei Buchstaben oder mit ⌃Leertaste; ↑/↓, Enter/Tab, Esc. Quellen: installierte Sprachserver (sourcekit-lsp, clangd, rust-analyzer, gopls, pyright, typescript-language-server, jdtls …), sonst Introspektion über Python, `javap` (Java) und Node.js, sonst Schlüsselwörter und Wörter im Code. Übersicht und Schalter in den Einstellungen › Code.

## [0.3.1] – 2026-10-19

### Behoben
- Kann eine lokale Seite nicht geladen werden, bietet die Fehlermeldung keine (leere) Link-Vorschau mehr an.

## [0.3.0] – 2026-10-19

### Hinzugefügt
- Apple Intelligence Writing Tools in Notizen: Umschreiben, Korrekturlesen, Zusammenfassen, Listen und Tabellen (Formatleiste, Format-Menü, ⇧⌘W, Kontextmenü).
- Code-Vorhersage in Codefeldern mit Apple Intelligence: graue Vorschläge passend zur Sprache, Tab übernimmt, Esc verwirft; abschaltbar in den Einstellungen.
- Auto-Formatierung im Codefeld: Klammern und Anführungszeichen schließen sich, Enter rückt passend ein (auch zwischen `{}`), schließende Klammern rücken aus, Backspace entfernt ganze Einrückungen, Tabs oder Leerzeichen je nach Sprache.
- „Code formatieren“ (⌥⇧F) mit installiertem Formatierer (ruff/black, prettier, swift-format, gofmt, rustfmt, clang-format, shfmt …), sonst eigenes Neu-Einrücken.

## [0.2.0] – 2026-10-19

### Hinzugefügt
- Codeblöcke erkennen Server (an der Ausgabe oder einem offenen Port): kein Abbruch nach dem Zeitlimit, Live-Ausgabe, „Stoppen“ beendet auch Unterprozesse, die Seite lässt sich direkt in der Notiz öffnen.

### Behoben
- Lokale Adressen ohne `http://` (z. B. `localhost:3000`, `192.168.1.5:8080`) werden beim Einbetten und Einfügen als `http`-Seite geöffnet statt per `https`.
- Lokale Seiten werden immer als Webseite dargestellt, nie als leere Link-Vorschau.

## [0.1.0] – 2026-10-19

Erste veröffentlichte Version für Apple Silicon (macOS 15.2 oder neuer).

### Hinzugefügt
- Bibliothek aus einzelnen `.folio`-Dateien mit echten Ordnern, Suche, angehefteten Notizen und `#tags`.
- Rich-Text-Editor mit Formatleiste, Codeblöcke mit Syntaxhervorhebung und Ausführung über lokale Interpreter.
- Eingebettete PDFs, Bilder, Dokumente und live dargestellte Webseiten, auch aus dem lokalen Netz (localhost).
- Zeichenblöcke mit PencilKit sowie Skizze, Foto oder Scan vom iPhone/iPad per Continuity Camera.
- Bilder per Drag & Drop und ⌘V einfügen, auch ohne aktives Textfeld.
- Textvorhersage mit Apple Intelligence (Foundation Models auf dem Gerät), abschaltbar in den Einstellungen.
- Import aus Apple Notizen inklusive verschachtelter Ordner.
- Oberfläche mit schwebenden Panels, eigenen Fensterknöpfen, Akzentfarben, hellem und dunklem Modus.
- Installer: DMG mit Programme-Verknüpfung und PKG (`make installer`).

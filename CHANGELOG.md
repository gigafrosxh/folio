# Changelog

Alle nennenswerten Änderungen an Folio stehen in dieser Datei.
Das Format folgt [Keep a Changelog](https://keepachangelog.com/de/1.1.0/), die Versionsnummern folgen [Semantic Versioning](https://semver.org/lang/de/).

Neue Einträge kommen unter **Unreleased**; `scripts/release.sh` macht daraus beim Release den Abschnitt der neuen Version.

## [Unreleased]

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

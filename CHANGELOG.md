# Changelog

Alle nennenswerten Änderungen an Folio stehen in dieser Datei.
Das Format folgt [Keep a Changelog](https://keepachangelog.com/de/1.1.0/), die Versionsnummern folgen [Semantic Versioning](https://semver.org/lang/de/).

Neue Einträge kommen unter **Unreleased**; `scripts/release.sh` macht daraus beim Release den Abschnitt der neuen Version.

## [Unreleased]

## [0.7.1] – 2026-10-20

### Behoben
- Gelöschte Code-Blöcke lebten in der gemeinsamen Sitzung weiter (z. B. blieb `a` nach dem Löschen von `a = 10` verfügbar). Beim Löschen wird die Sitzung jetzt neu gestartet, die übrigen verknüpften Blöcke werden im Hintergrund neu ausgeführt (außer Server), und ein laufender Block wird gestoppt.

### Hinzugefügt
- `make regression`: automatische App-Prüfungen mit einer Test-Bibliothek (u. a. gelöschte und verknüpfte Code-Blöcke).

## [0.7.0] – 2026-10-19

### Hinzugefügt
- ⇧↩ führt den Code-Block aus (zusätzlich zu ⌘↩), neue Code-Blöcke bekommen sofort den Cursor.
- Tastenkürzel für Werkzeuge: ⌃C Code-Block, ⌃T Numbers-Tabelle, ⌃D Zeichnung, ⌃L Checkliste, ⌃W Webseite, ⌃I Datei/Bild/PDF, ⌃G Image Playground, ⌃U Link, ⌃J KI-Chat, ⌃R Writing Tools, ⌃⇧R alle Code-Blöcke ausführen. In einem laufenden Code-Block stoppt ⌃C die Ausführung.
- Einstellungen › Tastenkürzel: alle Kürzel auf einen Blick, Werkzeug-Kürzel neu belegen, entfernen oder zurücksetzen, Warnung bei Doppelbelegung.

## [0.6.0] – 2026-10-19

### Hinzugefügt
- Verknüpfte Code-Blöcke wie in einem Notebook: Blöcke derselben Sprache in einer Notiz teilen sich eine laufende Sitzung (Python, JavaScript, Ruby, Bash, Zsh), z. B. `a = 10` in einem Block und `print(a)` im nächsten. Der letzte Ausdruck eines Blocks wird wie in einer REPL angezeigt. Im Code-Kopf: Sitzungsanzeige, „Alle Code-Blöcke ausführen“, „Sitzung neu starten“ und Verknüpfung pro Block abschaltbar. Stoppen unterbricht nur den laufenden Code, Variablen bleiben. Die Sitzung endet beim Schließen der Notiz oder der App.
- Autovervollständigung kennt Variablen aus verknüpften Blöcken und fragt die laufende Sitzung nach ihren Namen.
- Die aktuelle Version steht unten im Einstellungsfenster.

## [0.5.1] – 2026-10-19

### Behoben
- Autovervollständigung: Schnelles Weitertippen und Enter übernahm einen veralteten Vorschlag (z. B. `System.out.flush()` statt `println`). Die Liste wird jetzt sofort mit jedem Zeichen gefiltert, und nur noch passende Einträge werden übernommen.
- In die Notiz eingefügte KI-Antworten zeigen `Code` als Code statt mit Backticks und behalten verschachtelte Listen bei.
- Die Vorschlagsliste folgt dem hellen bzw. dunklen Modus der App und schneidet keine halbe Zeile mehr an.

## [0.5.0] – 2026-10-19

### Hinzugefügt
- KI-Chat mit Apple Intelligence (auf dem Gerät): schwebendes Panel neben der Notiz (✨ in der Aktionsleiste, ⌥⌘I), kennt die Notiz und auf Wunsch die Auswahl, antwortet live, Schnellaktionen (Zusammenfassen, Stichpunkte, Aufgaben, Fragen, Übersetzen), Antworten lassen sich in die Notiz einfügen oder kopieren; eine Unterhaltung pro Notiz.

### Geändert
- Text- und Code-Vorhersagen erscheinen schneller: Das Sprachmodell wird beim Start vorgeladen, jede Anfrage startet mit einer vorbereiteten Sitzung, kürzere Wartezeit nach dem Tippen, weniger Kontext und ein Cache. Gemessen: erste Vorhersage 1,1 s statt ca. 3,6 s, danach 0,86 s statt ca. 1,25 s.

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

# Changelog

Alle nennenswerten Änderungen an Folio stehen in dieser Datei.
Das Format folgt [Keep a Changelog](https://keepachangelog.com/de/1.1.0/), die Versionsnummern folgen [Semantic Versioning](https://semver.org/lang/de/).

Neue Einträge kommen unter **Unreleased**; `scripts/release.sh` macht daraus beim Release den Abschnitt der neuen Version.

## [Unreleased]

### Geändert
- Folio sucht jetzt bei jedem Start nach einer neuen Version und fragt, ob sie installiert werden soll (Update-Fenster mit Änderungen). Gilt auch für bestehende Installationen; abschaltbar unter Einstellungen › Allgemein › Updates.

## [0.12.0] – 2026-10-20

### Hinzugefügt
- Software-Update (#64): „Nach Updates suchen …“ im Folio-Menü und unter Einstellungen › Allgemein vergleicht die installierte Version mit dem neuesten GitHub-Release, zeigt die Änderungen und installiert auf Knopfdruck: Download, Prüfung der App, alte Version in den Papierkorb, neue an dieselbe Stelle, Neustart. Notizen und Einstellungen bleiben unberührt. Optional automatische Prüfung beim Start.

## [0.11.0] – 2026-10-20

### Hinzugefügt
- Microsoft SQL Server im Datenbank-Block (über `sqlcmd`), inklusive Schema, Primärschlüsseln und Änderungszahlen; getestet gegen einen echten SQL Server in Docker.
- SQL-Codefelder können auf Datenbanken zugreifen: Im Kopf des Codefelds wählst du eine Verbindung (aus der Notiz oder alle bisher in Folio angelegten) oder legst eine neue an. ⇧↩ führt das SQL darauf aus, das Ergebnis erscheint als Tabelle, und die Vorschläge kennen die Tabellen und Spalten. Ohne Verbindung läuft SQL wie bisher in einer SQLite-Datenbank im Arbeitsspeicher.

## [0.10.0] – 2026-10-20

### Hinzugefügt
- Datenbank-Block wie in DataGrip: Verbindung zu SQLite, PostgreSQL und MySQL/MariaDB direkt in der Notiz (Zylinder-Symbol, Einfügen › Datenbank-Abfrage oder ⌃⇧D). Verbindungsdialog mit „Verbindung testen“, Passwörter im macOS-Schlüsselbund, Schema-Ansicht mit Tabellen, Spalten, Typen und Primärschlüsseln (Doppelklick zeigt den Inhalt), SQL-Feld mit Hervorhebung und Vorschlägen für Tabellen- und Spaltennamen, Ausführen mit ⇧↩, Ergebnistabelle mit Zeilennummern und NULL-Anzeige, Ergebnis als CSV kopieren. Nutzt die installierten Clients sqlite3, psql und mysql.

## [0.9.0] – 2026-10-20

### Hinzugefügt
- Neuer Tab „Feedback“ in den Einstellungen: Er öffnet die Issues-Seite von Folio auf GitHub, wahlweise mit einem neuen Eintrag, in dem App- und macOS-Version schon stehen.

## [0.8.2] – 2026-10-20

### Behoben
- Die Popup-Animation des KI-Chats lief nicht: Die Sichtbarkeit hing an einer gespeicherten Einstellung, deren Änderung außerhalb der Animation ankommt. Das Panel wird jetzt eingefügt und danach in einem eigenen Schritt aus dem ✨-Knopf herausgefedert (und vor dem Entfernen dorthin zurückgeschrumpft).

## [0.8.1] – 2026-10-20

### Geändert
- Der KI-Chat öffnet sich mit einer Popup-Animation: Das Panel federt aus dem ✨-Knopf oben rechts heraus und schrumpft beim Schließen dorthin zurück.

## [0.8.0] – 2026-10-20

### Hinzugefügt
- Dezente Animationen: Blöcke erscheinen und verschwinden weich, die Notizliste ordnet sich animiert um, Auswahl und Hover blenden über, Ausgabe und Server-Leiste gleiten ein, Vorschlagsliste und KI-Chat blenden ein, Wechsel zwischen Notizen und das Ein-/Ausblenden der Seitenleiste sind animiert. Schalter unter Einstellungen › Darstellung; mit „Bewegung reduzieren“ in den Systemeinstellungen bleiben sie aus.

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

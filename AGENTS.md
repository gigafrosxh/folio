# AGENTS.md – Arbeitsanleitung für KI-Agenten (Claude, Codex …)

Folio ist eine macOS-Notizen-App (Swift, SwiftUI/AppKit, macOS 15.2+, Apple Silicon). Jede Notiz ist eine eigene
komprimierte `.folio`-Datei in einem normalen Ordnerbaum. Repository: <https://github.com/gigafrosxh/folio>.
Kommuniziert wird mit dem Nutzer auf **Deutsch**; Code, Kommentare und Commit-Titel folgen dem Stil im Repo.

## Feste Regeln

1. **Vor jeder Aufgabe die GitHub-Issues prüfen** (`gh issue list --state open`). Gibt es die Anfrage schon als Issue,
   wird genau dieses Issue abgearbeitet und im Commit mit `Closes #N` geschlossen.
2. **Jedes Update wird ein Release**: Eintrag unter `## [Unreleased]` in `CHANGELOG.md`, dann `make release V=X.Y.Z`.
   **Jeder gemeldete Bug („[Bug] …“-Issue) bekommt ein eigenes Patch-Release** (0.16.1, 0.16.2, …), Commit mit `Closes #N`.
3. **Folio nie selbst auf dem Mac des Nutzers installieren oder aktualisieren** – er aktualisiert selbst über den
   Update-Knopf. Kein `make install`, kein Ersetzen von `/Applications/Folio.app`.
4. **Nie mit der echten Bibliothek testen** (`~/Documents/Folio`). Immer eine Kopie oder eine leere Testbibliothek
   über `FOLIO_LIBRARY=<pfad>` verwenden. Backups landen dann automatisch in `<pfad>/.folio/backups`.
5. Systemänderungen (z. B. `brew install …`) nur nach ausdrücklicher Zustimmung des Nutzers.
6. Nichts löschen, was der Nutzer nicht ausdrücklich freigibt; beschädigte Notizen werden nie gelöscht, nur nach
   `.folio/damaged` verschoben.
7. **Jedes Issue hat eine Priorität** als Label `P0`–`P3` (P0 kritisch: Datenverlust, Absturz, Eingabe am falschen Ort;
   P1 hoch; P2 mittel; P3 niedrig). Neue Issues werden beim Anlegen priorisiert.
8. **Release-Ablauf pro Version** (ab 1.0, Vorgabe des Nutzers), z. B. für 1.1.0:
   `1.1.0-rc.1` → testen → P0 fixen → `rc.2` → testen → P0 fixen (falls vorhanden) → `rc.3` → P1 fixen → `rc.4` →
   P2 fixen → `rc.5` → P3 fixen → `rc.6` → Abschlusstests → `1.1.0` (stabil). Nach **jedem** RC wird getestet und neue
   Issues werden priorisiert angelegt; neue P0-Issues haben sofort Vorrang. Jede Version durchläuft denselben Ablauf.
9. **Übergabe bei knappem Kontingent:** Bevor Claudes Kontingent ausgeht, bekommt Codex im Terminal den Auftrag, genau
   dort weiterzumachen (Version, offene Issues, letzter Commit). Geht Codex' Kontingent aus, schreibt Codex in den
   Projekt-Thread, wo Claude weitermachen soll. Der Auftrag wird auch dann geschickt, wenn der andere gerade kein
   Kontingent hat – er wird dann eingeplant.

## Aufbau

| Pfad | Inhalt |
| --- | --- |
| `Sources/FolioCore` | Plattformnahe Logik ohne UI, voll getestet: Dateiformat (`FolioArchive`, `NoteFile`), Tags, Syntax-Highlighting, Code-Ausführung und Kernels, Datenbank-Clients, Updates, Versionen (`NoteHistory`), Papierkorb (`LibraryTrash`), Diagnose (`FolioDiagnostics`), Backups (`LibraryBackup`), Suche/Filter/Links/Vorlagen (`Organization.swift`), Markdown-Struktur, Audio-Analyse, Render-Skripte für KaTeX/Mermaid |
| `Sources/Folio/App` | App, Menüs (`FolioApp.swift`), Tastenkürzel, Update-Manager, Debug-Harness (`LayoutDebug`) und Selbsttests (`*SelfTest.swift`) |
| `Sources/Folio/Storage` | `NoteStore` (Bibliothek, offene Dokumente, Tabs, Split View, Fenster, Konflikte, Papierkorb, Vorlagen, Tags), `BackupManager`, `MarkdownTransfer`, Startvorlagen |
| `Sources/Folio/Model` | `NoteDocument`/`BlockModel` (Blöcke, Speichern, Undo für Blockoperationen), RTF-Codec |
| `Sources/Folio/Editor` | Editor, Formatleiste, Textansicht, Textvorhersage, PDF-Export, Suchen/Ersetzen (`FindBar`) |
| `Sources/Folio/Code` | Code-Blöcke, Ausführung, Kernels, Autovervollständigung |
| `Sources/Folio/Embeds` | PDF, Web, Bild, Datei, Zeichnung, Datenbank, Formel/Diagramm (`RenderedBlocks`), Audio |
| `Sources/Folio/Views` | Hauptfenster, Seitenleiste, Notizliste, Einstellungen, Sicherheits- und Organisationsansichten, Tab-Leiste |
| `Sources/folio-dump` | CLI: Notiz anzeigen, `--find`, `--check <datei|ordner>` (Diagnose), `--seed` |
| `Resources` | `Info.plist`, Icon, `Web/` (KaTeX 0.16.22, Mermaid 11.12.0, `render.html` – offline) |
| `scripts` | `build-app.sh`, `make-installer.sh`, `release.sh`, `ui-regression.sh` |

Dateiformat `.folio`: Magic `FOLI`, Version, Flags, LZFSE-Abschnitte (Meta-JSON zuerst, dann Body-JSON, dann
Anhänge), CRC-32 am Ende. Neue Felder immer optional dekodieren (`decodeIfPresent`), damit alte Notizen lesbar bleiben.
Folios eigene Daten liegen versteckt in `<Bibliothek>/.folio/` (`history`, `trash`, `templates`, `damaged`).

## Bauen, testen, veröffentlichen

```sh
make build          # swift build
make test           # Unit-Tests (FolioCoreTests), alle müssen grün sein
make regression     # UI-Regression mit Testbibliothek (scripts/ui-regression.sh)
make app            # build/Folio.app (ad-hoc signiert)
make installer      # DMG + PKG in dist/
make release V=X.Y.Z  # Info.plist + CHANGELOG hochzählen, taggen, DMG/PKG bauen, GitHub-Release anlegen
```

`release.sh` baut aus dem Tag in einem temporären Ordner; vorher müssen `Info.plist` und `CHANGELOG.md` committet
sein und unter `[Unreleased]` muss etwas stehen. Vorabversionen wie `make release V=1.0.0-rc.2` sind erlaubt (SemVer,
der Updater ordnet sie richtig ein; Releases bleiben „latest“, nicht „pre-release“, sonst findet der Updater sie nicht).
Signieren/Notarisieren (#63) läuft automatisch, sobald „Developer ID“-Zertifikate und das notarytool-Profil
`folio-notary` im Schlüsselbund sind (`docs/SIGNING.md`); bis dahin ad hoc. Der Updater prüft Signatur und Team-ID
(`UpdateManager.verifySignature`).

### Ohne Bildschirmzugriff testen (Debug-Harness)

Der Nutzer hat Claude keinen Bildschirmzugriff gegeben. Stattdessen Umgebungsvariablen für `.build/debug/Folio`:

- `FOLIO_LIBRARY=<kopie>` – Pflicht bei jedem Test.
- `FOLIO_OPEN=<notiz.folio>`, `FOLIO_LAYOUT_DUMP=1`, `FOLIO_DUMP_DELAY=<s>`, `FOLIO_SNAPSHOT=<datei.png>` – Notiz öffnen
  und das Fenster als Bild speichern (rendert über `cacheDisplay`; Webinhalte erscheinen nicht immer).
- `FOLIO_MENU_DUMP=1` – Menüeinträge mit Kürzeln ausgeben (Konflikte finden).
- Selbsttests (geben `ok`/`FAIL` je Prüfung aus): `FOLIO_SAFETY_TEST=1` (Versionen, Konflikte, Papierkorb, Backups),
  `FOLIO_ORG_TEST=1` (Vorlagen, Links, Filter, Unterordner, Tags, Markdown, Zuletzt geöffnet),
  `FOLIO_EDITOR_TEST=1` (Undo, Suchen/Ersetzen, Tabs, Split View, Fenster-Logik, Duplikate, Fokusmodus).
- Weitere: `FOLIO_RENDER_TEST=<ordner>` (Formeln/Diagramme offscreen), `FOLIO_TRANSCRIBE=<audio>`,
  `FOLIO_EXPORT_PDF=<pfad>`, `FOLIO_SAMPLE_MEDIA=<audio>`, `FOLIO_PERFORM=<werkzeug>`, `FOLIO_QUICKOPEN=1`, `FOLIO_MULTI=1`.

Beispiel: `cp -R ~/Documents/Folio /tmp/folio-kopie && rm -rf /tmp/folio-kopie/.folio && FOLIO_LIBRARY=/tmp/folio-kopie FOLIO_EDITOR_TEST=1 .build/debug/Folio`

Codex mit Computer Use braucht die Freigabe des Nutzers im Terminal („Allow Computer Use to use Folio“, Option 2 + Enter).

## Stand und nächste Schritte

Aktuelle Version: **1.0.0** (stabil; nächste Version laut Roadmap 1.1.0) (siehe `CHANGELOG.md`). Die Bugs #73–#77 aus dem Test von 0.16.0 sind als 0.16.1–0.16.5 behoben;
Codex testet 0.16 weiter und legt neue „[Bug]“-Issues an – jedes davon als nächstes Patch-Release beheben (0.16.6 …). Erledigte Roadmap-Pakete: 0.13 Medien, 0.14 Datensicherheit,
0.15 Organisation, 0.16 Editor & Multitasking, 0.17 Developer Experience (#23, #24, #25, #27, #30, #32), 0.18 KI & intelligentes Arbeiten (#33, #34, #35, #38, #39, #41), 0.19 Performance & Qualität (#56, #57, #58, #59, #60, #62, #65, #68, #69), 0.20 Quick Access (#85, #86, #87, #88, #89, #93).
**Nach 0.20 steht laut Nutzer das gründliche Testen an** (auch mit Codex, nur mit Bibliothekskopien; Bugs als „[Bug]“-Issues, jeder als eigenes Patch-Release).
**Vorgabe des Nutzers:** bis einschließlich 0.20 nur bauen, Unit-Tests laufen lassen und veröffentlichen; das gründliche Testen (auch durch Codex) kommt erst nach 0.20.

### Offene Punkte, die noch niemand geprüft hat

- **Mikrofonaufnahme** (Audioblock) wurde nie mit echtem Mikrofon getestet, nur Wiedergabe, Wellenform und Transkription.
- **Notiz in eigenem Fenster** (⌥⌘O) wurde nur über die Store-Logik getestet, nicht als echtes Fenster.
- **Klickbedienung** neuer Knöpfe (Formatleiste, Filter-Popover, Tab-Leiste, Fokusmodus-Hover) nur per Harness/Snapshot geprüft.
- **MSSQL lokal**: `sqlcmd` (mssql-tools 17) läuft auf dem Mac des Nutzers nicht, weil `libodbc` fehlt.
  Lösung wäre `brew install unixodbc` – **nur nach Zustimmung des Nutzers**.
- **Formel-Vorschau in hellen Snapshots** blieb leer (das Rendern selbst meldet Erfolg); vermutlich nur ein Snapshot-Effekt
  von `cacheDisplay` mit WKWebView, im echten Fenster prüfen.
- Ein Entwicklungs-Build aus `build/Folio.app` lief zeitweise beim Nutzer und hat dabei Versionen/Backups in der echten
  Bibliothek angelegt – das ist normales App-Verhalten, aber auf `/Applications/Folio.app` achten.

### Roadmap des Nutzers (Stand 20.10.2026)

| Version | Schwerpunkt | Issues |
| --- | --- | --- |
| 1.0.0 | erledigt: rc.2 (#99–#104, #107), rc.3 (#108, #109), rc.4 (#105, #106), stabil am 21.10.2026 | #63 offen bis Developer ID vorliegt |
| 1.1.0 | Organisation und Notizverwaltung | #13, #14, #15, #19 |
| 1.2.0 | Codeblöcke und Entwicklerfunktionen | #26, #28, #29, #31 |
| 1.3.0 | Medien, PDFs und Anhänge | #43–#46, #49 |
| 1.4.0 | KI-Erweiterungen und Ollama | #36, #37, #40, #42 |
| 1.5.0 | macOS-Integration und Quick Access | #50, #70, #90–#92 |
| 1.6.0 | Desktop-Widgets | #78–#84 |
| 1.7.0 | Obsidian-Import und Projektqualität | #61, #66, #67, #71 |

Jede Version folgt Regel 8 (rc.1 … rc.6, dann stabil).

### Themen der offenen Issues

- **Qualität:** #61 Absturzberichte.
- **Distribution:** #63 signierte/notarisierte Releases, #66 Issue-/PR-Vorlagen, #67 CONTRIBUTING + Architektur,
  #70 Shortcuts/AppleScript, #71 Obsidian-Import, #72 Datenschutz-Doku.
- **KI:** #36, #37, #40, #42 (Kontextmenü-Aktionen, Tag-Vorschläge, Antwort als Block, Ollama-Opt-in). KI-Kern ab 0.18: `Sources/FolioCore/AIContext.swift` (Abschnitte, Kontextbudget, BM25-Suche, Zitate, Chat-Archiv).
- **Code:** #26, #28, #29, #31 (Abhängigkeiten, Export, automatische Blocktests, Diff).
- **Medien:** #43–#46, #49, #50 (PDF-Suche/Annotationen, Bilder zuschneiden, Alt-Texte, Anhang-Metadaten, Web-Clipping).
- **Organisation:** #13 manuelle Sortierung, #14 gespeicherte Suchen, #15 Favoriten, #19 Metadaten/Wortstatistik.

### Arbeitsweise, die sich bewährt hat

- Logik zuerst in `FolioCore` mit Unit-Tests, dann UI; danach ein Selbsttest im Harness gegen eine Bibliothekskopie.
- Bei Änderungen am Dokumentmodell (`NoteStore.documents`, Tabs, Split) alle drei Selbsttests erneut laufen lassen.
- Menükürzel nach jeder Änderung mit `FOLIO_MENU_DUMP=1` auf Doppelbelegungen prüfen (`FOLIO_MENU_DUMP=all` zeigt auch
  Einträge ohne Kürzel). Achtung: macOS belegt ⌥⌘W („Alle schließen“); eine `CommandGroup(after: .saveItem)` verschwindet,
  sobald die App mehr als eine Szene hat.
- `swift test` nicht parallel zu einem anderen Agenten laufen lassen (die Datenbanktests teilen sich Ports/Sockets).

### Entwicklerfunktionen ab 0.17

- `Sources/FolioTerminal`: kleiner C-Adapter für `forkpty` (steuerndes Terminal; auch fish).
- `FOLIO_DEV_TEST=1` prüft stdin, Umgebungen, Fehlerzeilen, Ressourcenlimits und Terminal gegen `FOLIO_LIBRARY`.
- `python3 scripts/dev-regression.py` führt alle vier App-Selbsttests mit frischen Testbibliotheken aus und behält Logs/Fixtures im temporären Ordner. Vorher `make build`.
- Der Editor-Selbsttest benötigt eine zweite Notiz mit Anhang; das Skript erzeugt diese über `FOLIO_SAMPLE_MEDIA`.

### Qualität ab 0.19

- Zwei Testziele: `FolioCoreTests` (Kern, inkl. Fixtures alter Versionen in `Tests/FolioCoreTests/Fixtures`) und
  `FolioAppTests` (Editor-Modell, `@testable import Folio`). `NoteDocument.undoManager` ist weak – in Tests eine
  eigene Referenz halten.
- `scripts/dev-regression.py` führt DEV, SAFETY, ORG, EDITOR, KEY (Tastatur) und A11Y (VoiceOver-Audit) aus.
  Synthetische ⇧+Buchstabe-Ereignisse lösen SwiftUI-Menüaktionen nicht aus; der Tastaturtest ruft dafür den
  Menüeintrag zum Kürzel direkt auf.
- `make build` meldet Fehler im Format `error: <pfad>:<zeile>` – mit `grep "error:"` suchen, nicht `" error"`.
- CI: `.github/workflows/ci.yml` (macOS-26-Runner): Build, `swift test`, App-Paket.
- `NoteStore` ist auf `NoteStore+*.swift` verteilt; Setter sind `internal(set)`, damit die Erweiterungen sie nutzen können.

### Quick Access ab 0.20

- Kern: `Sources/FolioCore/QuickAccess.swift` (Deep-Link-Parser `FolioURL`, `CaptureWriter`, `CaptureQueue`, `SwitcherEntry`).
- App: `Sources/Folio/QuickAccess/` (Menüleiste, Schnellerfassung-Panel, globales Kürzel über Carbon `RegisterEventHotKey`,
  `CaptureService`, Deep Links, Einstellungen). Wartende Erfassungen liegen in `~/Library/Application Support/Folio/Wartende Erfassungen`;
  in Tests mit `FOLIO_CAPTURE_QUEUE=<ordner>` umlenken.
- Nicht geprüft: echtes globales Kürzel aus einer anderen App, Menüleisten-Fenster, Einfügen von Bildern in die Schnellerfassung.

### Release Candidate 1.0.0-rc.1

- Ab rc.1 keine neuen Funktionen mehr, nur Bugfixes bis 1.0.0 (Bugfix-Releases als rc.2, rc.3 …).
- Doku: `docs/PRIVACY.md` (#72), `SECURITY.md`, `docs/SIGNING.md`. Bei neuen Netzwerkzugriffen oder Speicherorten
  `docs/PRIVACY.md` mitpflegen.
- Hardened Runtime testen ohne Zertifikat: `codesign --force --options runtime --entitlements Resources/Folio.entitlements
  --sign - .build/debug/Folio`, dann `scripts/dev-regression.py`.
- Erststart auf „frischem System“ ohne Systemänderung: App aus dem DMG in den Scratch-Ordner kopieren und mit
  `CFFIXED_USER_HOME=<leer> HOME=<leer> FOLIO_LIBRARY=<leer>/Documents/Folio` starten – so bleiben die echten
  Einstellungen (`de.daniel.folio`) unberührt. Ein echter neuer macOS-Benutzer oder eine VM braucht die Zustimmung des Nutzers.
- Notizen werden mit `.sortedKeys` kodiert (#98), gleicher Inhalt ergibt gleiche Bytes.
- Auf dem Mac des Nutzers liegt in `/Applications` noch Folio 0.9.0 (ohne eingebauten Updater) – nicht anfassen.

### Testlauf nach 0.20 (Stand 0.20.4)

- Gefunden und behoben: #94 Start-Hänger durch `MenuBarExtra`-Bindung (0.20.1), #96 Listenzeichen im Titel (0.20.2),
  #97 Titelverlust bei Notizen ohne Text (0.20.3), #95 Datumszeile als Titel nach Schnellerfassung (0.20.4).
- Weitere Selbsttests: `FOLIO_QUICK_TEST` (braucht `FOLIO_CAPTURE_QUEUE`), `FOLIO_AI_TEST` (echtes Apple Intelligence),
  `FOLIO_SWEEP_TEST=<ausgabeordner>` gegen eine Kopie der echten Bibliothek (prüft jede Notiz auf stabile Titel/Tags/Text,
  Markdown-Rundweg, PDF-Export, Duplikat, Diagnose).
- Achtung bei SwiftUI-Bindungen auf `ThemeManager.settings`: jede Zuweisung löst ein Update aus, auch mit gleichem Wert –
  nur bei Änderung zuweisen (sonst Endlosschleife wie #94).
- Noch nicht geprüft: globales Kürzel aus einer anderen App, Menüleisten-Fenster, Bilder in der Schnellerfassung,
  Mikrofonaufnahme, eigenes Notizfenster als echtes Fenster, Update-Fenster im Dunkelmodus (Schnappschuss zeigt es leer,
  vermutlich nur ein Effekt von `cacheDisplay`).

### Abschlussprüfung rc.1

- 164 Unit-Tests, keine Fehler, ein Datenbanktest wegen fehlender Umgebung übersprungen.
- Alle sieben App-Selbsttests unter Hardened Runtime grün (DEV, SAFETY, ORG, EDITOR, KEY, QUICK, A11Y).
- Bibliothekskopie: 137 Notizen, 0 Fehler; acht bekannte Titelnormalisierungen älterer Importe separat als INFO.
- Der Sweep trennt Textblöcke mit Zeilenumbrüchen, damit an Blockgrenzen keine künstlichen Wörter entstehen.
  Unbekannte Titeländerungen und instabile Titel beim erneuten Öffnen bleiben Fehler.
- Details und Grenzen: `docs/RELEASE-1.0.0-rc.1.md`. Developer ID fehlt weiterhin; #63 bleibt offen.

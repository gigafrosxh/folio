# Folio

Folio ist eine native Notizen-App für macOS ab Version 15, geschrieben in Swift und SwiftUI mit AppKit. Text, Code und eingebettete Inhalte bleiben gemeinsam in einer lokalen Notizdatei. Die Oberfläche ist deutschsprachig.

## Funktionen

- Echte Ordner, Suche, angeheftete Notizen und `#tags`.
- Rich Text mit Formatierungen, gespeichert als RTF.
- Codeblöcke mit Syntaxhervorhebung und Ausführung über lokal installierte Interpreter oder Compiler; Befehle und Zeitlimit sind anpassbar.
- Eingebettete PDFs, Bilder und Dokumente sowie live dargestellte Webseiten.
- Numbers-Tabellen erstellen und extern bearbeiten.
- Bilder mit Image Playground erstellen, sofern auf dem Mac verfügbar.
- Import aus Apple Notizen.
- Heller und dunkler Modus, anpassbare Schriftarten, Akzentfarben und Code-Themes.
- Schwebende Bedienelemente mit Glas-, Material- oder deckender Darstellung; Glas verwendet auf älteren macOS-Versionen einen Material-Ersatz.

## Dateien statt Datenbank

Standardmäßig liegt die Bibliothek in `~/Documents/Folio`. Jede Notiz ist eine einzelne `.folio`-Datei; Ordner entsprechen Verzeichnissen. Der Bibliotheksort ist anpassbar. Die Dateien lassen sich mit gewöhnlichen Dateisicherungen sichern und über den Finder verwalten.

PostgreSQL ist dafür nicht erforderlich: Ein dateibasierter Index aus den Metadaten reicht für Notizliste, Tags und Suche. `FolioArchive.readMeta(at:)` öffnet die Datei per Memory-Mapping und dekodiert nur die vorn liegende Metadatensektion. Inhalt und Anhänge müssen dafür nicht dekomprimiert werden. Der Suchtext liegt ebenfalls in den Metadaten. Die vollständige CRC-Prüfung erfolgt beim vollständigen Öffnen einer Notiz.

### Das `.folio`-Format

Die genaue Implementierung steht in `Sources/FolioCore/FolioArchive.swift`. Ganzzahlen sind Little Endian. Der Container ist folgendermaßen aufgebaut:

| Abschnitt | Inhalt |
| --- | --- |
| Header | 4 Byte Kennung `FOLI`, `UInt16` Version (aktuell 1), `UInt16` Flags (Bit 0: LZFSE) |
| Metadaten | LZFSE-komprimiertes JSON: UUID, Titel, Vorschau, Tags, Erstellungs- und Änderungsdatum, Pin-Status und Suchtext |
| Inhalt | LZFSE-komprimiertes JSON mit den Blöcken; unter anderem RTF-Daten, Quellcode, Sprache, Ausgabe, URLs und Anhangsreferenzen |
| Anhänge | `UInt32` Anzahl; je Anhang `UInt32` JSON-Headerlänge, JSON-Header und komprimierte Datensektion |
| Prüfsumme | `UInt32` CRC-32 über sämtliche vorangehenden Bytes |

Jede Datensektion enthält zuerst die unkomprimierte Länge (`UInt64`), dann die gespeicherte Länge (`UInt64`) und anschließend die gespeicherten Bytes. Leere Sektionen haben Länge null. Anhangsheader enthalten UUID, Dateinamen, Typkennung und die Kennzeichnung für Pakete. Dokumentpakete wie `.numbers` können als serialisierte `FileWrapper`-Daten eingebettet werden. `NoteFile` bündelt Metadaten, Blöcke und Anhänge und speichert atomar. Komprimierung ist keine Verschlüsselung.

## Bauen und starten

Voraussetzungen: macOS 15 oder neuer, Xcode 27 mit ausgewählten Kommandozeilenwerkzeugen und Swift 6.4. Das Swift Package verwendet den Swift-5-Sprachmodus. Für die Ausführung von Code müssen die jeweiligen Interpreter bzw. Compiler installiert sein; für Tabellen wird Numbers benötigt.

Im Projektverzeichnis:

```sh
make build                     # Swift-Package bauen
make test                      # Kerntests ausführen
make app                       # Release-App: build/Folio.app
make run                       # App bauen und öffnen
make install                   # App nach ~/Applications/Folio.app kopieren
CONFIG=debug make app           # Debug-App erstellen
./scripts/build-app.sh --install --run
```

`--install` ersetzt eine vorhandene `~/Applications/Folio.app`. Bei Kombination mit `--run` wird die installierte Kopie geöffnet. Die Bibliothek bleibt dabei erhalten. Das Skript funktioniert auch bei Aufruf außerhalb des Projektverzeichnisses.

Das Build-Skript übernimmt das Programm, `Info.plist`, das Icon und vorhandene SwiftPM-Ressourcenbundles in das App-Bundle und signiert es ad hoc. Diese lokale Signatur ist keine Developer-ID-Signatur oder Notarisierung für eine Veröffentlichung. Für die Nutzung der Systemintegrationen sollte das App-Bundle gestartet werden.

Das Icon lässt sich ohne zusätzliche Grafikwerkzeuge reproduzieren:

```sh
swift scripts/make-icon.swift Resources
```

Das Skript zeichnet mit AppKit ein bernsteinfarbenes Notizblatt, erzeugt vorübergehend ein vollständiges Iconset mit 1×/2×-Varianten von 16 bis 1024 Pixeln und schreibt über `iconutil` die Datei `Resources/AppIcon.icns`. Falls `iconutil` die Konvertierung ablehnt, schreibt es dieselben PNG-Varianten direkt in einen ICNS-Container. `make clean` entfernt die SwiftPM-Build-Produkte und `build/Folio.app`.

## Berechtigungen

Beim Import aus Apple Notizen und beim Erstellen von Numbers-Tabellen fragt macOS nach der Erlaubnis, die jeweilige App zu steuern. Der Zugriff lässt sich unter **Systemeinstellungen → Datenschutz & Sicherheit → Automation → Folio** verwalten. Die deutsche Zweckbeschreibung dafür ist in `Resources/Info.plist` hinterlegt. Je nach gewähltem Bibliotheksort kann macOS außerdem den Zugriff auf den Dokumenteordner anfragen.

## Projektstruktur

| Pfad | Aufgabe |
| --- | --- |
| `Package.swift` | Swift-Package, App-Produkt und Kernbibliothek |
| `Sources/FolioCore/` | Dateiformat, Datenmodelle, Tags, Sprachen, Syntaxhervorhebung und Codeausführung |
| `Sources/Folio/` | SwiftUI-/AppKit-App und Systemintegrationen |
| `Sources/Folio/Model/` | Bearbeitbare Notizen und Blöcke sowie RTF-Konvertierung |
| `Sources/Folio/Storage/` | Dateibasierte Bibliothek und Speicherung |
| `Sources/Folio/Theme/` | Erscheinungsbild, Code-Themes und schwebende Oberflächen |
| `Tests/FolioCoreTests/` | Tests der Kernbibliothek |
| `Resources/` | Bundle-Metadaten und generiertes App-Icon |
| `scripts/` | App-Bundle bauen und Icon generieren |
| `build/Folio.app` | Fertiges lokales App-Bundle |

Die Dateitypdeklaration registriert `.folio` als `de.daniel.folio.note` mit der Rolle „Editor“. Die App muss vom Finder übergebene Datei-URLs selbst entgegennehmen und die betreffende Notiz öffnen.

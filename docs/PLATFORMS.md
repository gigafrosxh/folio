# Plattformgrenzen von FolioCore (#313)

`FolioCore` ist die gemeinsame Schicht für Mac, iPad und iPhone. Dieser Vertrag legt fest, was darin wo laufen darf.

## Vertrag

1. **Überall (macOS und iOS):** Dateiformat und Notizmodell (`FolioArchive`, `NoteFile`, `NoteIdentity`), Metadaten
   (`NoteMetaBuilder`, `NoteTitle`, `TagParser`, `LinkGraph`), Sicherheit beim Sichern (`NoteSaveTransaction`,
   `SaveRevisions`, `FileStamp`, `NoteHistory`, `LibraryTrash`), Bibliothek einlesen (`LibraryScanner`), Organisation,
   Suche, Syntaxfärbung, PDF-Text. Diese Dateien importieren nur Foundation und Apple-Frameworks, die es auf beiden
   Plattformen gibt (Compression, CoreGraphics, CoreText, ImageIO, PDFKit, AVFoundation).
2. **Nur macOS (`#if os(macOS)`):** alles, was Prozesse startet oder ein Terminal braucht – Code-Ausführung
   (`CodeRunner`, `ProcessGroup`, `Kernel`, `PseudoTerminal` mit dem C-Ziel `FolioTerminal`), Vervollständigung über
   Interpreter und Sprachserver (`IntrospectionCompleter`, `LSPCompleter`, `CompletionEngine`), Formatierer
   (`CodeFormatter`), Datenbank-Clients (`DatabaseClient`), Absturzberichte (`CrashReports`) und ZIP-Sicherungen
   (`LibraryBackup.create/verify/restore`). iOS erlaubt keine Kindprozesse.
3. **Kein UI-Framework im Kern:** weder AppKit noch UIKit noch SwiftUI. Was Rich Text dekodiert (RTF → Text), macht die
   Plattform und übergibt Klartext (z. B. `NoteMetaBuilder.Block`).
4. **Dateisystem über `FileOperations`** für alles, was Notizen verschiebt, ersetzt oder löscht (#314), damit
   Fehlerfälle in Tests nachgestellt werden können.

## Prüfung (Plattformmatrix)

| Plattform | Wo geprüft |
| --- | --- |
| macOS | `swift build` / `swift test` in der CI und vor jedem Release |
| iOS-Simulator, Debug und Release | CI-Job „iPad (Simulator)“: baut `FolioPad` und damit `FolioCore` für iOS und führt den iPad-Selbsttest aus (#316, #341) |

Eine neue Datei im Kern, die etwas nur für macOS braucht, steht vollständig in `#if os(macOS)`; sonst schlägt der
iOS-Build in der CI fehl.

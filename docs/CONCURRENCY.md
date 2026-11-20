# Nebenläufigkeit (#218)

Stand 1.11.6: **Alle Ziele laufen im Swift-6-Sprachmodus** (#309) – `FolioCore`, `Folio`, Widgets, Teilen, iPad, `folio-bench` und beide Testziele. Der Compiler prüft Datenrennen damit vollständig; neue Warnungen sind Fehler. Diese Übersicht hält fest, welche Typen
`@unchecked Sendable` sind, was sie schützt und welche Warnungen der strenge Concurrency-Check meldet.

## `@unchecked Sendable` – Inventar

| Typ | Veränderlicher Zustand | Schutz / Invariante |
| --- | --- | --- |
| `Kernel` (Kern) | Ausgabe-Puffer, laufende Aufträge, Prozess | `NSLock` um alle Puffer und die Auftragsliste; der Prozess wird nur einmal gestartet |
| `Kernel.Job`, `LockedBool` | Abbruch-/Speicherflag | `LockedBool` mit `NSLock`; `Job` selbst ist nach dem Anlegen unveränderlich |
| `CompletionEngine` | nur `let`-Referenzen auf Anbieter | unveränderlich nach `init` |
| `LSPCompleter`, `LSPSession`, `Once` | Sitzungen, Lesepuffer, offene Anfragen | `NSLock`; `Once` stellt sicher, dass eine Antwort nur einmal zurückgegeben wird |
| `PseudoTerminal` | `exited`, `onOutput`, `onExit` | `NSLock` – **seit 1.10.0 auch für die beiden Handler**, die der Hauptthread setzt und der Lesethread aufruft (vorher ungeschützt) |
| `InterpreterLocator` | Suchpfad-Cache | `NSLock` |
| `CodeRun`, `OutputCapture`, `LockedData`, `LockedPIDs`, `LockedFlag`, `GroupProcess` | laufender Prozess, Eingabe, Ausgabe, Prozess-Identitäten | je ein `NSLock`; `CodeRun.ProcessJob` ist `Sendable` (nur `let`, Handler `@Sendable`) |
| `JSONBox` (Kern) | eine JSON-Antwort des Sprachservers | wird über eine Continuation genau einmal übergeben und danach nur gelesen |
| `IntrospectionCache`, `IntrospectionBuffer` | Ergebnis-Cache, Lesepuffer | `NSLock` |
| `SyntaxHighlighter.Compiled` | keiner (nur `let`-Regexe) | unveränderlich; `NSRegularExpression` ist threadsicher |
| `LibraryScanner` | Metadaten-Cache | `NSLock`; `concurrentPerform` schreibt jede Notiz in einen eigenen Index des Ergebnis-Puffers |
| `NoteStore.LibrarySnapshot` (App) | keiner | wird im Hintergrund gebaut und danach nur gelesen (#220) |
| `RunManager.OutputBuffer` (App) | Ausgabe, „flush geplant“ | `NSLock` |
| `UpdateManager.DownloadDelegate` (App) | Continuation | `NSLock`; **seit 1.10.0** wird sie unter dem Lock genommen und so genau einmal fortgesetzt (vorher konnten Fehler- und Abschlussmeldung sich überschneiden) |
| `KeyboardSelfTest` (Test-Harness) | Ereignis-Zähler | nur im Selbsttest, auf dem Hauptthread |

## Strenger Check (`-strict-concurrency=complete`)

`swift build --target FolioCore -Xswiftc -strict-concurrency=complete` meldet in 1.10.0 noch 13 Stellen:

- **Bewusst sicher, nur nicht beweisbar** (6): `LibraryScanner` schreibt in `concurrentPerform` in getrennte Indizes eines
  `UnsafeMutableBufferPointer`; `Kernel` übergibt einen Block an `DispatchQueue`.
- **Nicht-`Sendable`-Captures** (7): `CodeRun.ProcessJob` und ein Lese-Handler in `OutputCapture` werden in
  `@Sendable`-Closures verwendet. Beide sind nach dem Start unveränderlich bzw. lock-geschützt; sie werden beim Wechsel auf
  den Swift-6-Modus als `Sendable` markiert oder zu Actors.
- Behoben in 1.10.0: `LSPCompleter.specs` (jetzt `Sendable`), `PseudoTerminal`-Handler, `DownloadDelegate`.

Nächster Schritt: Ziel für Ziel (zuerst `FolioCore`) in den Swift-6-Modus wechseln, sobald diese Liste leer ist.

## Swift 6 (1.11.6, #309, #318)

Umgestellt ohne Unterdrückung ganzer Ziele. Was dabei geändert wurde:

- Hauptthread-Code ist ausdrücklich `@MainActor`: `AppDelegate`, `FolioServices` (Dienste-Menü), `ColorPanelBridge`, der
  PDF-Koordinator, der Bild-Cache `EditedImage.cache`, `record` in `folio-bench`.
- `NSEvent` im lokalen Tastatur-Monitor und AppleScript-Ergebnisse bleiben auf dem Hauptthread (`nonisolated(unsafe)`
  nur für diese eine Übergabe innerhalb von `MainActor.assumeIsolated`).
- Rückrufe über Threads hinweg sind `@Sendable` (Server-Erkennung, Lese-Handler) oder laufen über `Task { @MainActor … }`
  (Ablegen von Links, Link-Vorschau mit `async`-API).
- Die Testziele erfassen keine Testfall-Instanz mehr in nebenläufigen Tasks.

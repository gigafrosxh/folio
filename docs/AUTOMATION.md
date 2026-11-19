# Folio automatisieren (#70)

Folio lässt sich aus Kurzbefehlen, AppleScript und über `folio://`-Links steuern. Alles läuft lokal; Notizen werden
nie gelöscht oder überschrieben, offene Notizen bekommen Änderungen über ihren Editor.

## Kurzbefehle

In der Kurzbefehle-App unter „Folio“: **Notiz erstellen** (Titel, Text → gibt die Notiz zurück), **Notizen suchen**
(alle Wörter in Titel, Tags oder Text), **Notiz öffnen**, **An Notiz anhängen** (mit Datumszeile wie die Schnellerfassung).

## AppleScript

```applescript
tell application "Folio"
    set neueID to create note "Einkauf" with text "Milch"
    set treffer to search notes "milch"            -- Titel; mit „returning ids true“ die IDs
    append to note neueID with text "Brot"
    open note "Einkauf"                             -- ID, Titel oder Suchbegriff
end tell
```

Fehler (z. B. unbekannte Notiz) kommen als AppleScript-Fehler zurück, ohne dass etwas geändert wird.

## Links

`folio://capture?text=…`, `folio://search?q=…`, `folio://new?title=…&text=…`, `folio://note/<id>` (siehe #89).

## Prüfen ohne Bildschirm

`FOLIO_AUTO_TEST=1` (Teil von `scripts/dev-regression.py`) prüft Automation und Kurzbefehle; in einer Testkopie aus
`scripts/make-test-app.sh` auch echtes AppleScript an den eigenen Prozess.

# Developer Experience – v0.17.0

## Reproduzierbare Prüfung

- `make test`: Core-Tests inklusive stdin, großer Eingaben beim Abbruch, Umgebungen, Ausgabe-/Speicherlimits, Zeitlimit, Kindprozessen, Fehlerdiagnosen und Terminal (inklusive Standardshell und Ctrl-C).
- `make build && python3 scripts/dev-regression.py`: Entwickler-, Datensicherheits-, Organisations- und Editor-Selbsttests in neu erzeugten Bibliotheken. Das Skript zeigt deren Pfade und behält Logs und Testnotizen. Es greift nicht auf die echte Bibliothek zu.
- `make regression`: bestehende UI-Regression für verknüpfte Blöcke und Löschen.
- Menüprüfung: `FOLIO_LIBRARY=<testordner> FOLIO_LAYOUT_DUMP=1 FOLIO_MENU_DUMP=1 FOLIO_DUMP_DELAY=2 .build/debug/Folio` (mit externem Timeout starten).

Der Editor-Selbsttest benötigt eine zweite Notiz mit Bildanhang; das Skript erzeugt sie automatisch. Ein fehlender SQL-Server/Docker kann den entsprechenden Datenbanktest überspringen.

## Manuelle Bedienprüfung mit Testbibliothek

1. Python-Codeblock mit `print(input("Name? "))` einfügen. Im Blockmenü stdin vorgeben oder interaktive Eingabe aktivieren. Ausführen, Eingabe senden, danach einen wartenden Lauf stoppen.
2. Über das Terminal-Symbol oder ⌃` das Panel öffnen. `echo Hallo` ausführen; einen Codeblock über „Im Terminal ausführen“ starten. `sleep 30` mit ⌃C abbrechen; danach muss die Shell weitere Befehle annehmen.
3. In „Ausführungsumgebung“ ein existierendes Arbeitsverzeichnis, eine Variable und einen Python-Interpreter eintragen. Mit `import os; print(os.getcwd(), os.getenv("TEST"))` in zwei Notizen verschiedene Umgebungen prüfen. Speichern und erneut öffnen.
4. Große Ausgaben erzeugen, einklappen, kopieren und leeren. Nach erneutem Öffnen bleibt der eingeklappte Zustand erhalten. Einen Syntaxfehler ausführen und auf die Diagnose klicken; nach Korrektur verschwindet die Markierung.
5. In den Einstellungen ein kleines Zeit-/Speicherlimit wählen und einen wartenden bzw. speicherintensiven Codeblock ausführen. Zeitlimits gelten nicht für erkannte Server. Terminalbefehle laufen bewusst interaktiv ohne Code-Laufzeitlimit; Vollbildprogramme werden in der reinen Textansicht nicht emuliert.

Die automatisierten App-Tests prüfen Modell, Ausführung und App-Integration. Sie ersetzen keine vollständige Prüfung jedes Mausklicks oder von VoiceOver.

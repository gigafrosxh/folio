# Freigabeprüfung 1.0.0-rc.1 – 20. Oktober 2026

## Ergebnis

- `make test`: 142 Core-Tests und 22 App-Tests, keine Fehler; ein umgebungsabhängiger Datenbanktest übersprungen.
- Die sieben bereits ausgeführten App-Selbsttests unter Hardened Runtime sind grün: DEV, SAFETY, ORG, EDITOR, KEY, QUICK, A11Y (21 Steuerelemente, keines ohne Namen).
- Die erneute Prüfung einer separaten Bibliothekskopie umfasst 137 Notizen: Öffnen/Speicherdarstellung, Titel, Tags, Text, Blockarten, Anhänge, Markdown-Rundweg, PDF-Export, Duplikate und Dateidiagnose. Ergebnis: 0 Fehler.
- Acht Titel älterer Importe werden beim Speichern erwartungsgemäß normalisiert: abgekürzte Titel aus Apple Notizen werden aus der ersten Textzeile abgeleitet, mehrfache Leerzeichen zusammengeführt. Die Inhalte bleiben erhalten. Unbekannte Titeländerungen und beim erneuten Öffnen instabile Titel bleiben Testfehler.
- Der zunächst gemeldete Markdown-Verlust war ein Testfehler: benachbarte Textblöcke wurden ohne Trennzeichen zu künstlichen Wörtern verkettet. Der Test verwendet jetzt Zeilenumbrüche; Gegenproben prüfen Blockgrenzen und unzulässige Titeländerungen.
- Der vorbereitende Installer-Test prüfte DMG, PKG und Signatur sowie den Erststart mit leerem Benutzerprofil (Bibliothek und Vorlagen angelegt). Die Veröffentlichung wird erneut aus dem Git-Tag gebaut.

## Release-Inhalt

- Bug #98: stabile Kodierung und Inhaltsvergleich vermeiden doppelte Versionen ohne Inhaltsänderung.
- SemVer-Vorabversionen, Signaturprüfung im Updater, vorbereitete Developer-ID-Signierung und Notarisierung.
- Datenschutz-, Sicherheits- und Signierdokumentation (#72).
- Kein Developer-ID-Zertifikat vorhanden: ad hoc signiert, nicht notarisiert. #63 bleibt bis zur tatsächlichen signierten/notarisierten Veröffentlichung offen.

## Grenzen

Automatisierte Prüfungen ersetzen keine vollständige manuelle Bedienprüfung. Die noch offenen Hardware-/UI-Prüfungen stehen in AGENTS.md, unter anderem Mikrofon, globales Kürzel aus einer anderen App, Menüleisten-Fenster und Bilder in der Schnellerfassung.

Die echte Bibliothek und die installierte App wurden für diese Abschlussprüfung nicht verändert.

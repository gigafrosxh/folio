# Datenschutz und Sicherheit (#72)

Stand: Folio 1.1.0. Kurzfassung: **Folio hat kein Konto, keinen Server und keine Telemetrie.** Deine Notizen
bleiben als Dateien auf deinem Mac. Ins Netz geht Folio nur für die Update-Prüfung und für Inhalte, die du selbst in
eine Notiz einbettest.

## Wo Folio Daten speichert

| Was | Ort | Hinweis |
| --- | --- | --- |
| Notizen | Bibliotheksordner, Standard `~/Documents/Folio` | Eine `.folio`-Datei pro Notiz (LZFSE-komprimiert, **nicht verschlüsselt**). Ordner und Dateien kannst du im Finder sehen, sichern und synchronisieren. |
| Versionen, Papierkorb, Vorlagen, KI-Chats, beschädigte Notizen | `<Bibliothek>/.folio/` (`history`, `trash`, `templates`, `chats`, `damaged`) | Versteckter Ordner, wandert mit der Bibliothek. Versionen und Papierkorb enthalten auch Inhalte, die du in der Notiz schon gelöscht hast. |
| Backups | `~/Library/Application Support/Folio/Backups` oder der in den Einstellungen gewählte Ordner | ZIP-Archive der ganzen Bibliothek, unverschlüsselt. Wählst du einen Cloud-Ordner, landen die Backups beim jeweiligen Anbieter. |
| Widget-Daten | `~/Library/Application Support/Folio/Widgets/snapshot.json` | Titel, Ordner, Datum, Anpinn-Status und Checklisten-Fortschritt der Notizen, damit die Widgets sie anzeigen können. Vorschauen und Checklisten-Punkte nur, wenn „Notizinhalte in Widgets zeigen“ eingeschaltet ist (Standard: aus). Die Widgets dürfen nur diese Datei lesen und keine Notizen ändern. |
| Wartende Schnellerfassungen | `~/Library/Application Support/Folio/Wartende Erfassungen` | Nur solange die Bibliothek nicht beschreibbar ist; danach werden sie in die Notiz geschrieben und gelöscht. |
| Einstellungen, Entwurf der Schnellerfassung, zuletzt geöffnete Notizen | macOS-Benutzereinstellungen (`de.daniel.folio`) | Der Entwurf enthält den getippten Text, bis du ihn sicherst oder verwirfst. |
| Passwörter von Datenbankverbindungen | macOS-Schlüsselbund | Nie in Notizen oder Einstellungen. Eine Notiz enthält nur Host, Port, Datenbank und Benutzername. |
| Anmeldungen in Web-Einbettungen (Cookies) | WebKit-Datenspeicher von Folio | Bleiben gespeichert, damit z. B. Moodle-Seiten angemeldet bleiben. |

Folio verschlüsselt Notizen nicht selbst. Für Schutz auf dem Gerät sorgt FileVault; wer die Bibliothek mit iCloud
Drive, Dropbox o. Ä. synchronisiert, gibt die Dateien diesem Anbieter.

## Netzwerkzugriffe

| Wann | Wohin | Was übertragen wird |
| --- | --- | --- |
| Beim Start (abschaltbar: Einstellungen → „Bei jedem Start nach Updates suchen und fragen“) und bei „Nach Updates suchen“ | `api.github.com`, `github.com`, `raw.githubusercontent.com` | Eine normale Anfrage nach dem neuesten Release und dem Changelog. Keine Kennung, keine Notizinhalte. GitHub sieht wie bei jedem Webseitenaufruf deine IP-Adresse. |
| Beim Installieren eines Updates | `github.com` (Release-Download) | Download des DMG. Folio installiert es nur, wenn Bundle-ID, Version und Signatur stimmen (siehe unten). |
| Web-Block, Link-Vorschau, verlinkte PDFs | Die Adresse, die in der Notiz steht | Die Seite wird wie in Safari geladen, sobald die Notiz offen ist; die Seite sieht deine IP-Adresse und ihre Cookies. |
| Datenbank-Block, SQL-Code-Block mit Verbindung | Der eingetragene Datenbankserver | Beim Öffnen der Notiz lädt Folio das Schema (Tabellen und Spalten), Abfragen nur auf Knopfdruck. |
| Code-Blöcke | Was dein Programm tut | Folio selbst sendet nichts; ein ausgeführtes Programm darf aber wie jedes Programm auf deinem Mac ins Netz. |

Formeln (KaTeX) und Diagramme (Mermaid) werden **offline** aus der App heraus gerendert; es werden keine Schriften
oder Skripte aus dem Netz geladen.

## Künstliche Intelligenz und Spracherkennung

- KI-Chat, Zusammenfassungen und Textvorhersage nutzen **Apple Intelligence auf dem Gerät** (Foundation Models).
  Das Modell läuft lokal; Folio schickt keine Notizen an einen Cloud-Dienst.
- KI-Chats werden in `<Bibliothek>/.folio/chats` gespeichert und lassen sich im Chat löschen.
- Die Transkription von Audioaufnahmen läuft lokal mit Apples Spracherkennung auf dem Gerät.

## Berechtigungen

macOS fragt nur, wenn du die Funktion benutzt:

| Berechtigung | Wofür |
| --- | --- |
| Mikrofon | Audioaufnahme in einer Notiz |
| Spracherkennung | Transkription von Audioaufnahmen |
| Automation (Apple Events) | Import aus Apple Notizen, Tabellen in Numbers erstellen |
| Lokales Netzwerk | Web-Blöcke mit `localhost` oder Geräten im eigenen Netz |

Folio braucht keinen Festplattenvollzugriff und keine Bedienungshilfen-Berechtigung; das globale Kürzel der
Schnellerfassung funktioniert ohne sie.

## Code-Ausführung

Code-Blöcke, Terminal und Kernels starten echte Programme (Python, Node, Swift, Shell, …) **mit deinen
Benutzerrechten**. Das ist kein Sandbox-Betrieb: ein Programm kann Dateien lesen und löschen, auf die du Zugriff
hast. Folio führt Code-Blöcke nie von selbst aus, nur auf Knopfdruck. Für die Autovervollständigung startet Folio
installierte Sprachserver (z. B. sourcekit-lsp, pyright, rust-analyzer); sie analysieren den Code in einem
temporären Ordner, manche führen dabei aber Build-Skripte aus. Schutz vor Versehen:

- Zeitlimit (Standard 30 Sekunden; erkannte Server ausgenommen), Ausgabelimit (1 MB), optional ein Speicherlimit.
- Zurückgelassene Prozesse werden am Ende beendet.
- Öffne Notizen anderer Leute wie Skripte aus dem Internet: Code erst lesen, dann ausführen.

## Signatur und Updates

- Ab dem ersten notarisierten Release ist Folio mit einer Developer ID signiert, mit „Hardened Runtime“ gebaut und von
  Apple notarisiert (#63, Ablauf in [SIGNING.md](SIGNING.md)). Bis dahin sind Releases nur ad hoc signiert; die
  Release-Notizen sagen jeweils, welcher Fall gilt.
- Der eingebaute Updater ersetzt nur die App, nie Notizen oder Einstellungen. Er prüft vor dem Installieren,
  dass die Signatur der neuen Version intakt ist, und – sobald Folio mit einer Developer ID signiert ist – dass sie
  vom selben Entwickler-Team stammt. Die alte Version landet im Papierkorb.

## Was Folio nicht tut

- Keine Analyse, keine Telemetrie, keine Absturzberichte an Dritte, keine Werbung.
- Kein Konto und keine Synchronisation über eigene Server.
- Keine Weitergabe von Notizinhalten an KI-Anbieter.

## Sicherheitslücken melden

Siehe [SECURITY.md](../SECURITY.md).

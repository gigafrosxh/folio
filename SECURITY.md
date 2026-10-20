# Sicherheit

## Unterstützte Versionen

Sicherheitskorrekturen gibt es für die jeweils neueste Version von Folio (auch Vorabversionen wie `1.0.0-rc.1`).
Aktualisiere über **Folio → Nach Updates suchen …**.

## Eine Lücke melden

Bitte **kein öffentliches Issue** für Sicherheitslücken anlegen. Melde sie vertraulich über
[GitHub → Security → Report a vulnerability](https://github.com/gigafrosxh/folio/security/advisories/new).

Hilfreich sind: betroffene Version, Schritte zum Nachstellen (am besten mit einer Beispielnotiz, die keine privaten
Daten enthält) und was ein Angreifer damit erreichen kann. Du bekommst innerhalb einer Woche eine Rückmeldung. Die
Korrektur erscheint als eigenes Patch-Release; im Changelog wirst du auf Wunsch genannt.

## Was als Sicherheitslücke gilt

- Eine Notiz-, Markdown- oder Importdatei, die beim **Öffnen** Code ausführt, Dateien liest oder schreibt oder Daten
  ins Netz schickt (über das in [docs/PRIVACY.md](docs/PRIVACY.md) Beschriebene hinaus).
- Umgehen der Signaturprüfung des Updaters.
- Passwörter aus dem Schlüsselbund, die in Notizen, Logs, Backups oder Exporten landen.
- Ein Deep Link (`folio://…`), der ohne Zutun Inhalte verändert oder löscht.

Nicht dazu gehört, dass ein Code-Block nach Klick auf „Ausführen“ mit deinen Rechten läuft – das ist gewollt und in
[docs/PRIVACY.md](docs/PRIVACY.md#code-ausführung) beschrieben.

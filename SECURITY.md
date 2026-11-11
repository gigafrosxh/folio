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

## Automatische Sicherheitstests

Diese Tests laufen bei jedem Push im CI und vor jedem Release (`make release` bricht bei roten Tests ab):

- **Notizdateien** (`SecurityRegressionTests`): Abschnitte über 1 GiB, Abschnitte über 128 MiB mit einem Kompressionsverhältnis über 1000:1, mehr als 4 GiB entpackt
  oder mehr als 100.000 Anhänge werden abgelehnt, bevor etwas entpackt wird. Eine Datei, die mehr enthält als angegeben, gilt als beschädigt.
- **Updates** (`UpdateInstallTests`, `SecurityAppTests`): Nur gültig signierte Apps mit derselben Bundle-ID, genau der angekündigten
  Version und einer neueren Version als der installierten; sobald Folio eine Developer ID hat, nur vom selben Team.
- **Links** (`folio://`): Nur `new` verändert die Bibliothek, und erst nach einer Rückfrage. Ungültige Links ändern nichts.
- **Importe**: Markdown liest Bilder nur aus seinem eigenen Ordner (kein `..`, kein absoluter Pfad, kein Symlink hinaus) und übernimmt
  nur Links mit `http`, `https`, `mailto` und `folio`. Formeln und Diagramme erreichen die Renderseite nur als JSON-Zeichenkette.
- **Geheimnisse**: Datenbank-Passwörter stehen nur im Schlüsselbund, nie in einer Notiz, und werden aus Fehlermeldungen entfernt.
  Absturzberichte enthalten keine Pfade und Adressen.

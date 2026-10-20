# Signieren und Notarisieren (#63)

`make release V=X.Y.Z` (bzw. `scripts/make-installer.sh`) signiert und notarisiert automatisch, sobald die
Voraussetzungen auf dem Mac vorhanden sind. Fehlen sie, baut das Skript wie bisher ad hoc signierte Pakete und sagt das
in der Ausgabe und in den Release-Notizen.

## Einmalige Einrichtung

1. **Apple Developer Program** (bezahlte Mitgliedschaft) – nur damit gibt es Developer-ID-Zertifikate.
2. **Zertifikate** in den Anmelde-Schlüsselbund holen: Xcode → Einstellungen → Accounts → Team → „Zertifikate
   verwalten …“ → `+` → **Developer ID Application** und **Developer ID Installer**. Prüfen:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   security find-identity -v | grep "Developer ID Installer"
   ```

3. **Zugang zum Notar-Dienst** als Schlüsselbund-Profil `folio-notary` speichern (fragt Apple-ID, app-spezifisches
   Passwort von <https://account.apple.com> und Team-ID ab; alternativ `--key/--key-id/--issuer` für einen App Store
   Connect API-Schlüssel):

   ```sh
   xcrun notarytool store-credentials folio-notary
   ```

## Was das Skript macht

| Schritt | Befehl |
| --- | --- |
| App signieren | `codesign --options runtime --timestamp --entitlements Resources/Folio.entitlements` mit der ersten „Developer ID Application“-Identität |
| DMG signieren | `codesign --timestamp` |
| PKG signieren | `pkgbuild --sign "Developer ID Installer: …" --timestamp` |
| Notarisieren | `xcrun notarytool submit … --keychain-profile folio-notary --wait` für DMG und PKG |
| Ticket anheften | `xcrun stapler staple` |
| Prüfen | `spctl --assess --type open --context context:primary-signature` |

Die letzte Ausgabezeile lautet `SIGNED=developer-id NOTARIZED=yes` bzw. `SIGNED=adhoc NOTARIZED=no`;
`release.sh` wählt danach den Installationshinweis in den Release-Notizen.

Überschreiben lässt sich alles per Umgebungsvariable: `SIGN_IDENTITY`, `INSTALLER_IDENTITY`, `NOTARY_PROFILE`.

## Entitlements

`Resources/Folio.entitlements` gibt der Hardened Runtime nur, was Folio braucht:

- `com.apple.security.automation.apple-events` – Import aus Apple Notizen, Tabellen in Numbers.
- `com.apple.security.device.audio-input` – Audioaufnahme.

Keine Ausnahmen für JIT, unsignierten Code oder Bibliotheksvalidierung: Folio lädt keine fremden Bibliotheken in den
eigenen Prozess; Interpreter für Code-Blöcke laufen als eigene Prozesse.

## Updates zwischen signierten Versionen

Der Updater installiert eine neue Version nur mit intakter Signatur. Ist die laufende App mit einer Developer ID
signiert, muss die neue Version dieselbe Team-ID haben (`UpdateManager.verifySignature`, Tests in
`Tests/FolioAppTests/UpdateInstallTests.swift`). Der Wechsel von ad hoc zu Developer ID ist dadurch ohne Zutun
möglich, ein späterer Wechsel des Teams dagegen nicht.

## Fehlersuche

```sh
xcrun notarytool history --keychain-profile folio-notary
xcrun notarytool log <submission-id> --keychain-profile folio-notary
codesign -dv --verbose=4 build/Folio.app
spctl --assess -vv --type execute build/Folio.app
```

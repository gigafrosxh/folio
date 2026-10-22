# Changelog

Alle nennenswerten Änderungen an Folio stehen in dieser Datei.
Das Format folgt [Keep a Changelog](https://keepachangelog.com/de/1.1.0/), die Versionsnummern folgen [Semantic Versioning](https://semver.org/lang/de/).

Neue Einträge kommen unter **Unreleased**; `scripts/release.sh` macht daraus beim Release den Abschnitt der neuen Version.

## [Unreleased]

## [1.2.2] – 2026-10-22

### Neu
- **PDF importieren** (Ablage › PDF importieren …): Jede PDF wird eine eigene Notiz. Titel und Text werden zu bearbeitbarem, durchsuchbarem Notiztext (umbrochene Zeilen und Silbentrennung werden zusammengefügt, mehrseitige PDFs bekommen Seitenüberschriften), die Original-PDF hängt darunter. Für Scans ohne Text gibt es einen Hinweis; passwortgeschützte PDFs werden gemeldet (#130).

### Geändert
- Ruhigeres, einheitlicheres Aussehen (#131): Die Formatleiste und die Notiz-Werkzeuge nutzen dieselbe Milchglas-Fläche wie die übrigen schwebenden Elemente, die Panels werfen weichere Schatten, der Fensterhintergrund hat nur noch einen dezenten Farbschimmer, und die Notizliste zeigt flache Zeilen wie Apple Notizen (nur Auswahl und Darüberfahren sind hinterlegt). „Eigenschaft hinzufügen“ steht jetzt bei den anderen Werkzeugen unter der Notiz statt über dem Titel.

## [1.2.1] – 2026-10-21

### Behoben
- In der Notizliste konnten zwei Notizen gleichzeitig ausgewählt aussehen, wenn eine Notiz durch eine Änderung in eine andere Gruppe rutschte (z. B. nach „Heute“): Die Liste ließ eine veraltete Kopie stehen. Notizen behalten jetzt ihre Identität, wenn sie die Gruppe wechseln (#128).
- ⌥⌫ löscht nur noch das Wort vor dem Cursor in der aktuellen Zeile. Auf einer leeren oder nur mit Leerzeichen gefüllten Zeile löschte es bisher bis in den Text darüber (#129).

### Geändert
- Absatzstile folgen beim Schreiben von selbst: ↩ nach dem Titel beginnt eine Überschrift, ↩ nach einer Überschrift normalen Text (abschaltbar unter Einstellungen › Editor › Absätze). „- “ oder „* “ am Zeilenanfang wird ein Aufzählungspunkt, „[] “ eine Checkbox; umbrochene Zeilen eines Listenpunkts beginnen unter dem Text statt unter dem Punkt (#125).
- Links werden in der Akzentfarbe unterstrichen statt blau (#126).
- Der Graph ist ein eigener Bereich in der Seitenleiste; ein Klick auf eine Notiz kehrt zur Notizliste zurück (#127).
- Der Apple-Intelligence-Assistent erledigt Aufträge jetzt selbst, statt sie zusammenzufassen: Notizen anlegen, Text ergänzen, verknüpfen, taggen, umbenennen und verschieben. Unter der Antwort steht, was er geändert hat, ein Klick öffnet die Notiz. Er löscht nie etwas; jede Änderung landet im Versionsverlauf. Antworten kommen in ganzen Sätzen statt als Stichpunktliste (#124).

## [1.2.0] – 2026-10-21

### Neu – Graph und Links
- **Graph** (Darstellung › Graph, ⌃⌘G): alle Notizen als Punkte, Links als Linien. Ziehen verschiebt, zwei Finger zoomen, ein Klick öffnet die Notiz (#110).
- **Lokaler Graph** unter jeder Notiz: die Notiz und ihre Nachbarn, 1–3 Schritte weit (#111).
- **Filter**: nach Tag, Ordner und Abstand zur offenen Notiz, Farben nach Ordner oder Tag; die Einstellungen bleiben erhalten (#113).
- **Suche im Graph**, Nachbarn beim Darüberfahren, ⌥-Klick auf zwei Notizen zeigt den kürzesten Weg, verwaiste Notizen sind gestrichelt und lassen sich ausblenden (#114).
- **Link-Index**: Verknüpfungen werden pro geänderter, umbenannter oder gelöschter Notiz nachgeführt, ohne die Bibliothek neu zu lesen (#119).
- **Backlinks und unverlinkte Erwähnungen**: Unter jeder Notiz stehen die Notizen, die auf sie verweisen; „Unverlinkte Erwähnungen suchen“ findet Notizen, die den Titel nur nennen, und „Verlinken“ macht daraus einen Link (#112).
- **[[Wiki-Links]]**: `[[Titel]]` und `[[Titel|Text]]` verlinken Notizen über den Titel. Links auf noch nicht vorhandene Notizen sind blasser; ein Klick legt die Notiz an. Im Link-Dialog (`[[`) gibt es „… als neue Notiz verlinken“ (#115).
- **Linkvorschau**: Wer mit dem Zeiger auf einem Notizlink verweilt, sieht Titel und Textauszug (#116).
- **Tagesnotizen**: Ablage › Tagesnotiz (⌃⌘D) öffnet die Notiz von heute („2026-10-21“) im Ordner „Tagesnotizen“; Ordner und Vorlage in den Einstellungen (#117).
- **Vorlagen mit Variablen**: zusätzlich `{{titel}}`, `{{cursor}}` und Datumsformate wie `{{datum:yyyy-MM-dd}}`; der Cursor steht nach dem Anlegen an `{{cursor}}` (#118).
- **Eingebettete Notizen**: Einfügen › Notiz einbetten … oder eine Zeile `![[Titel]]` mit Return zeigt eine andere Notiz schreibgeschützt an, immer auf dem aktuellen Stand; Einbettungen in der eingebetteten Notiz werden nur verlinkt, Kreise sind so ausgeschlossen (#120).
- **Eigenschaften**: Status, Datum, Zahl, Ja/Nein und Text pro Notiz; die Suche findet sie mit `name:wert`, z. B. `status:offen` oder `fällig:*` (#121).

### Hinweis
- Notizen mit eingebetteten Notizen lassen sich erst ab Folio 1.2.0 öffnen. Alle anderen Notizen bleiben mit älteren Versionen kompatibel.

## [1.1.1] – 2026-10-21

### Behoben
- Die Folio-Widgets erschienen nicht in der Widget-Galerie, weil die Widget-Erweiterung beim Start abstürzte. Sie startet jetzt wie eine von Xcode gebaute Erweiterung; das Build-Skript prüft das (#123).

## [1.1.0] – 2026-10-21

### Neu – Widgets für den Schreibtisch
- **Angepinnte Notizen** und **Letzte Notizen** (klein, mittel, groß): Ein Klick öffnet die Notiz in Folio (#78, #79).
- **Schnellnotiz**: Knöpfe für die Schnellerfassung und eine neue Notiz (#80).
- **Checkliste**: Fortschritt einer Checkliste, standardmäßig die zuletzt bearbeitete mit offenen Punkten; per Rechtsklick auf eine Notiz › „Im Widget zeigen“ wählbar (#81).
- **Notiz des Tages**: jeden Tag eine andere Notiz oder die gewählte (#82).
- **Datenschutz**: Widgets zeigen standardmäßig nur Titel, Ordner, Datum und Fortschritt, keine Notizinhalte. „Einstellungen › Schnellzugriff › Widgets › Notizinhalte in Widgets zeigen“ erlaubt Vorschauen; bei gesperrtem Mac blendet macOS sie aus (#83).
- **Datenversorgung**: Folio schreibt nach Änderungen einen kleinen Snapshot; die Widgets lesen nur diesen, in einer Sandbox ohne Zugriff auf die Bibliothek, und zeigen verständliche Hinweise, wenn Folio noch nie lief oder die Bibliothek fehlt (#84).

### Geändert
- Release Candidates gibt es nur noch für Hauptversionen; Fehlerbehebungen erscheinen als Patch-Versionen (1.1.1, 1.1.2 …).

## [1.0.0] – 2026-10-21

Erste stabile Version. Gegenüber 1.0.0-rc.4 keine Änderungen am Programm; alle in den Release Candidates gefundenen Fehler (#98–#109) sind behoben.

### Geprüft
- 167 Unit-Tests und alle App-Selbsttests (Entwicklerfunktionen, Datensicherheit, Organisation, Editor, Tastatur, Schnellzugriff, VoiceOver) unter Hardened Runtime.
- Kopie einer echten Bibliothek mit 137 Notizen: Öffnen, Speichern, Titel, Tags, Markdown, PDF-Export, Duplikat und Diagnose ohne Fehler.
- Installer: DMG und PKG vollständig, Signatur intakt, Erststart mit leerem Benutzerprofil legt Bibliothek und Vorlagen an.

### Bekannt
- Folio ist weiterhin nur ad hoc signiert und nicht notarisiert, bis ein „Developer ID“-Zertifikat vorliegt (#63, Einrichtung in `docs/SIGNING.md`).

## [1.0.0-rc.4] – 2026-10-21

### Behoben
- Die Regler in den Einstellungen sehen einheitlich aus und rasten in sinnvollen Schritten ein: Zeitlimit in 5 s, maximale Ausgabe in 50 KB, Editorbreite in 10 pt. Bisher zeichnete „Zeitlimit“ eine gestückelte Leiste und „Max. Ausgabe“ ließ sich kaum gezielt einstellen (#105).
- Das Hilfe-Menü hat Inhalt: „Folio-Hilfe“ (⌘?) öffnet die Anleitung, dazu Tastenkürzel, Datenschutz, Änderungen und „Fehler melden“. Der englische Resteintrag „Toggle Sidebar“ ist weg (#106).

## [1.0.0-rc.3] – 2026-10-21

### Behoben
- Notizen lassen sich jetzt auch aus dem Editor löschen: „Ablage → Notiz in den Papierkorb legen“. Das Kontextmenü der Notizliste heißt wie bei Ordnern „In den Papierkorb legen“ statt „Löschen“ (#108).
- Bei schmalem Fenster mit offenem KI-Chat wurde der Editor auf einen Buchstaben Breite zusammengedrückt. Der Chat wird jetzt schmaler und legt sich, wenn es nicht reicht, über die Notiz; die Formatleiste bekommt bei Bedarf eine zweite Zeile und eine kleinste Variante, sodass alle Werkzeuge erreichbar bleiben (#109).

## [1.0.0-rc.2] – 2026-10-20

### Behoben
- Der Schnellwechsel (⌘P) bekommt sofort den Tastaturfokus. Bisher landete Getipptes im Suchfeld der Seitenleiste oder sogar in der Notiz dahinter (#99).
- Direkt nach ⌘N Getipptes landet vollständig in der neuen Notiz, auch wenn vorher das Suchfeld aktiv war; bisher gingen die ersten Zeichen ins Suchfeld (#100).
- Mehrzeiliger Text, der in die Titelzeile eingefügt wird, macht nur noch die erste Zeile zum Titel; der Rest ist normaler Fließtext (#101).
- Eine neue Notiz ist auch bei aktiver Suche in der Liste sichtbar: Anlegen setzt die Suche zurück (#102).
- Die Formatleiste schneidet bei schmalerem Fenster keine Werkzeuge mehr ab: Code, Tabelle, Formel, Diagramm, Audio, Datei, Zeichnung und Webseite wandern in ein Menü „Einfügen“, bei noch weniger Platz Ausrichtung, Link und Writing Tools in „Mehr“ (#103).
- Alle neun Reiter der Einstellungen sind sichtbar; „Feedback“ verschwand bisher im »-Überlaufmenü (#104).
- ⌘W schließt bei mehreren offenen Tabs nur den aktuellen Tab, wie in Safari; erst beim letzten Tab das Fenster (#107).

## [1.0.0-rc.1] – 2026-10-20

Release Candidate für Folio 1.0: keine neuen Funktionen mehr, nur noch Fehlerbehebungen bis 1.0.0.

### Sicherheit
- Signierte und notarisierte Releases vorbereitet (#63): Die Release-Skripte signieren mit einer „Developer ID“ (Hardened Runtime, nur die nötigen Entitlements für Mikrofon und Apple Events), signieren das Installationspaket, lassen DMG und PKG von Apple notarisieren und heften das Ticket an. Ohne Zertifikat bleibt es bei der Ad-hoc-Signatur; die Release-Notizen sagen, welcher Fall gilt. Einrichtung in `docs/SIGNING.md`.
- Der Updater installiert eine neue Version nur noch, wenn ihre Signatur intakt ist, und – sobald Folio mit einer Developer ID signiert ist – nur vom selben Entwickler-Team. Ein veränderter oder fremder Download wird abgelehnt.

### Behoben
- Der Versionsverlauf legte manchmal eine zusätzliche Version an, obwohl sich am Inhalt nichts geändert hatte, weil derselbe Inhalt in unterschiedlicher Reihenfolge gespeichert wurde. Notizen werden jetzt immer gleich kodiert, und der Vergleich ignoriert die Reihenfolge (#98).

### Geändert
- Updates erkennen Vorabversionen: `1.0.0-rc.1` gilt als neuer als 0.20.x und älter als 1.0.0, `rc.10` als neuer als `rc.2`.

### Dokumentation
- `docs/PRIVACY.md`: wo Folio Daten speichert, wann es ins Netz geht, KI und Spracherkennung auf dem Gerät, Berechtigungen, Risiken der Code-Ausführung, keine Telemetrie (#72).
- `SECURITY.md`: wie man Sicherheitslücken vertraulich meldet.

### Prüfung
- 164 Unit-Tests ohne Fehler (ein umgebungsabhängiger Test übersprungen), sieben App-Selbsttests unter Hardened Runtime und vollständiger Bibliothekstest auf einer Kopie mit 137 Notizen.
- Der Bibliothekstest unterscheidet bekannte Titelnormalisierungen älterer Importe von unerwarteten Titeländerungen und prüft Wortgrenzen zwischen Textblöcken korrekt.

## [0.20.4] – 2026-10-20

### Behoben
- Schnellerfassung in eine leere Notiz machte die Datumszeile („— 20. Okt. 2026, 19:31 —“) zum Titel. Datumszeilen der Schnellerfassung zählen nicht mehr als Titel; eine leere Notiz heißt danach wie die erste erfasste Zeile (#95).

### Intern
- Neue Selbsttests: `FOLIO_QUICK_TEST` (Schnellerfassung, Warteschlange, Links, Kürzel), `FOLIO_AI_TEST` (echte Antworten von Apple Intelligence), `FOLIO_SWEEP_TEST=<ordner>` (jede Notiz einer Bibliothekskopie öffnen, speichern, exportieren).

## [0.20.3] – 2026-10-20

### Behoben
- Notizen ohne Text (z. B. nur ein Bild oder ein Code-Block, auch neue leere Notizen) verloren beim Speichern ihren Titel und hießen danach „Ohne Titel“. Sie behalten ihn jetzt (#97).

## [0.20.2] – 2026-10-20

### Behoben
- Beginnt eine Notiz mit einer Liste, enthielten Titel und Dateiname das Listenzeichen und einen Tabulator („•	Juli 14“). Listenzeichen, Checkboxen und Einrückung gehören jetzt nicht mehr zum Titel und zur Vorschau (#96).

## [0.20.1] – 2026-10-20

### Behoben
- Folio 0.20.0 hing direkt nach dem Start (100 % CPU, keine Reaktion): Das Menüleisten-Symbol löste eine endlose Neuberechnung der Oberfläche aus (#94).

## [0.20.0] – 2026-10-20

### Neu
- **Menüleiste** (#85): Ein Folio-Symbol in der Menüleiste sucht Notizen, zeigt angepinnte und zuletzt geöffnete und öffnet die Schnellerfassung, auch wenn das Hauptfenster geschlossen ist. Abschaltbar unter Einstellungen › Schnellzugriff; mit Symbol läuft Folio weiter, wenn das letzte Fenster zu ist (Dock-Klick öffnet es wieder).
- **Globales Kürzel** (#86): ⌃⌥⌘N öffnet die Schnellerfassung aus jeder App (ohne Bedienungshilfen-Freigabe). Das Kürzel lässt sich ändern oder abschalten; ist es von einer anderen App belegt, sagt Folio das.
- **Schnellerfassung** (#87): Ein kleines schwebendes Fenster speichert Text, Links (als Vorschau) und eingefügte Bilder mit ⌘↩ in die Inbox (`Inbox.folio`, angepinnt) oder eine zuletzt geöffnete Notiz. Esc schließt, der Entwurf bleibt erhalten; „Verwerfen“ löscht ihn bewusst. Auch über Ablage › Schnellerfassung.
- **Schnellwechsel** (#88): ⌘P findet jetzt neben Notizen auch Ordner und Tags (unscharfe Suche; „/“ nur Ordner, „#“ nur Tags) und springt mit ↩ dorthin.
- **Folio-Links** (#89): `folio://note/<id>`, `folio://capture?text=…&target=inbox`, `folio://search?q=…`, `folio://new?title=…&text=…` und `folio://open` – für Kurzbefehle, Skripte und andere Apps. Ungültige Links werden mit einer verständlichen Meldung abgelehnt.
- **Erfassen ohne Datenverlust** (#93): Ist die Bibliothek nicht erreichbar, schreibgeschützt oder wird die Zielnotiz gleichzeitig geändert, landet die Erfassung sicher in einer Warteschlange außerhalb der Bibliothek und wird automatisch nachgetragen (beim Aktivieren und jede Minute). Offene Notizen erhalten Erfassungen über den Editor, ungesicherte Änderungen bleiben erhalten; beschädigte Notizen werden nie überschrieben.

## [0.19.0] – 2026-10-20

### Geändert
- **Große Bibliotheken schneller** (#62): Der Bibliotheksscan liest Metadaten parallel und merkt sich unveränderte Notizen; die Suche senkt Texte nur einmal ab und die Notizliste wird nicht bei jedem Neuzeichnen neu berechnet. Benchmark mit 3.000 Notizen: Scan unter 0,3 s, Suche je Tastendruck rund 15 ms.
- **Symbolische Links** (#56): Links in der Bibliothek werden nur verfolgt, wenn sie innerhalb der Bibliothek bleiben; Schleifen werden erkannt. Übersprungene Links stehen im „…“-Menü der Seitenleiste.
- **VoiceOver** (#60): Alle Symbolknöpfe haben gesprochene Namen, Seitenleisten-Einträge, Notizkarten und Tabs sind Knöpfe mit Auswahlzustand und Zusatzaktionen. Details in `docs/ACCESSIBILITY.md`.
- Versionsverlauf hat jetzt das Kürzel **⌥⌘Y** (⇧⌘Y gehört dem macOS-Dienst „Neue Haftnotiz“).

### Behoben
- „Nächster/Vorheriger Tab“, „Notiz duplizieren“ (⌘D) und „In neuem Fenster öffnen“ blieben im Menü manchmal ausgegraut, sodass ihre Kürzel nichts taten (gefunden durch den neuen Tastaturtest).

### Intern
- Tests: Regressionstests für Blockoperationen in einem neuen App-Testziel (#57), Roundtrip- und Beschädigungstests für alle Blockarten, Unicode und große Anhänge (#58), Migrationstests mit Dateien, die mit dem Code von 0.1 bis 0.17 geschrieben wurden (#69, `scripts/make-fixtures.sh`), Tastatur-Selbsttest `FOLIO_KEY_TEST` (#59) und Zugänglichkeits-Audit (#60) in `scripts/dev-regression.py`.
- CI mit GitHub Actions: Build, alle Tests und App-Paket bei jedem Pull Request und Push (#65).
- `NoteStore`, `FolioApp` und der Editor sind in kleinere Dateien aufgeteilt (#68).

## [0.18.0] – 2026-10-20

### Neu
- **Chatverlauf bleibt erhalten** (#33): Unterhaltungen mit Apple Intelligence werden pro Notiz in der Bibliothek gespeichert (`.folio/chats`) und sind nach dem Schließen, Wechseln und Neustarten wieder da. „Neu“ beginnt von vorn und löscht den gespeicherten Verlauf.
- **Notizen vergleichen** (#34): Im Chat fügt „+ Notiz“ weitere Notizen hinzu (oder Rechtsklick in der Liste › „Zum KI-Chat hinzufügen“). Alle ausgewählten Notizen bilden den gemeinsamen Kontext; die Schnellaktion „Vergleichen“ zeigt Gemeinsamkeiten, Unterschiede und Widersprüche.
- **Antworten mit Quellen** (#35): Die KI bekommt nummerierte Abschnitte und zitiert sie als [1], [2]. Zitate und die Quellenliste unter jeder Antwort sind klickbar und springen zur markierten Stelle in der Notiz.
- **Bibliothek fragen** (#38): Im Chat „Ganze Bibliothek“ wählen oder ⌥⇧⌘I: Folio sucht lokal die passenden Stellen in allen Notizen und beantwortet die Frage mit Quellenangaben.
- **Kontext sichtbar** (#39): Eine Anzeige zeigt, wie viel vom Kontext des Sprachmodells belegt ist (Token, Abschnitte, Notizen) und welche Ausschnitte es sieht; was nicht mehr hineinpasst, wird genannt.
- **Ohne Apple Intelligence** (#41): Folio erklärt, warum die KI fehlt (ausgeschaltet, Modell lädt, Mac oder macOS nicht unterstützt), bietet die passenden Systemeinstellungen an und zeigt im Chat passende Fundstellen statt einer Antwort. Das KI-Symbol ist dann gedimmt.

## [0.17.0] – 2026-10-20

### Neu
- **Terminal pro Notiz** (#23): interaktive Shell mit Live-Ausgabe, Eingabe, ⌃C/⌃D, Verlauf und Neustart. Öffnen über die Werkzeugleiste oder ⌃`; Codeblöcke lassen sich direkt darin ausführen. Funktioniert auch mit fish als Standardshell; die Ausgabe ist eine begrenzte Textansicht.
- **Standardeingabe** (#24): stdin pro Codeblock vorgeben oder während eines eigenen Prozesses eingeben. Vorgegebene Eingaben funktionieren auch in verknüpften Python-Sitzungen.
- **Ausführungsumgebung pro Notiz** (#25): eigene Interpreter, Arbeitsverzeichnis, Umgebungsvariablen und Zeitlimit, zusammen mit der Notiz gespeichert.
- **Ausgaben verwalten** (#27): einklappen, kopieren und leeren; große Ausgaben werden begrenzt, Anfang und Ende bleiben erhalten.
- **Fehlerstellen** (#30): Compiler- und Laufzeitdiagnosen markieren betroffene Codezeilen; ein Klick auf die Diagnose springt zur Stelle.
- **Ressourcenlimits** (#32): konfigurierbare Ausgabe- und Speichergrenzen, Zeitlimit und Aufräumen zurückgelassener Kindprozesse bei eigenen Codeprozessen. Verknüpfte Sitzungen begrenzen Ausgabe und Speicher; nicht abbrechbare Sitzungen werden beendet. Das Terminal bleibt für interaktive Befehle ohne Code-Laufzeitlimit offen.

### Behoben
- Große stdin-Eingaben blockieren die Oberfläche nicht und können beim Prozessabbruch keinen SIGPIPE-Absturz auslösen.
- Verzögerte Live-Ausgabe überschreibt nach Laufende keine Fehler- oder Abbruchmeldungen mehr.

## [0.16.5] – 2026-10-20

### Behoben
- Nach dem Neuladen einer Notiz (Version wiederhergestellt, Tag umbenannt, externe Änderung übernommen) wirkte ⌘Z auf die alte, unsichtbare Fassung. Diese Schritte werden jetzt verworfen, neue Blockoperationen lassen sich sofort rückgängig machen (#77).
- Suchen/Ersetzen und Notizlinks greifen nach dem Neuladen nicht mehr auf die alte Textansicht zu.

## [0.16.4] – 2026-10-20

### Behoben
- „Link zu Notiz“ (⌥⌘K) ohne Textcursor (oder mit dem Cursor in einem Codeblock) tat nichts. Der Link kommt jetzt in eine neue Zeile am Ende der Notiz (#76).

## [0.16.3] – 2026-10-20

### Behoben
- Fokusmodus mit geöffneter Split View: Menübefehle und Kürzel wirkten auf die ausgeblendete rechte Notiz; jetzt gehen sie an die sichtbare (#75).

## [0.16.2] – 2026-10-20

### Behoben
- „Webseite einbetten“ hat ein funktionierendes Kürzel: ⌥⌘L. ⌥⌘W gehört macOS („Alle schließen“) und kam nie an (#74).

## [0.16.1] – 2026-10-20

### Behoben
- Im Ablage-Menü fehlten seit 0.16.0 Sichern, Schnell öffnen, Zuletzt geöffnet, Vorlagen, Markdown-Import/-Export, Versionsverlauf und PDF-Export samt ihren Kürzeln (⌘S, ⌘P, ⇧⌘Y, ⇧⌘E, ⌥⌘E). Sie sind wieder da (#73).

## [0.16.0] – 2026-10-20

### Neu
- **Undo/Redo für Blöcke** (#3): Einfügen, Löschen und Verschieben von Blöcken sowie Einstellungen wie Codesprache, Bildgröße oder Papier lassen sich mit ⌘Z/⇧⌘Z rückgängig machen und wiederholen, in einer Reihenfolge mit dem Tippen.
- **Suchen und Ersetzen** (#9): ⌘F sucht in der offenen Notiz über Text-, Code- und SQL-Blöcke mit Hervorhebung aller Treffer, ⌘G/⇧⌘G springen weiter, ⌃⌘F öffnet gleich das Ersetzen (einzeln oder alle, rückgängig machbar). Optionen für Groß-/Kleinschreibung und ganze Wörter.
- **Fokusmodus** (#10): ⇧⌘F blendet Seitenleiste, Notizliste, Tabs, Symbolleiste und Statusanzeige aus; die Symbolleiste erscheint, wenn der Zeiger nach oben geht. Esc oder ⇧⌘F beendet ihn.
- **Tabs und Fenster** (#11): ⌘-Klick oder „In neuem Tab öffnen“ öffnet eine Notiz zusätzlich in einem Tab, ⌘T legt eine neue Notiz im Tab an, ⇧⌘[ / ⇧⌘] wechseln. „In neuem Fenster öffnen“ (⌥⌘O) zeigt eine Notiz in einem eigenen Fenster.
- **Split View** (#12): ⌥-Klick oder „Rechts daneben öffnen“ (⌥⌘\\) zeigt zwei Notizen nebeneinander, unabhängig scroll- und bearbeitbar. Die Notiz mit der Akzentlinie empfängt Menübefehle und Kürzel.
- **Duplizieren** (#16): ⌘D oder Kontextmenü kopiert eine Notiz samt Blöcken und Anhängen mit neuen IDs.

### Geändert
- Dieselbe Notiz in Tab, Split View und Fenster ist ein einziges Dokument: Änderungen erscheinen überall sofort, gespeichert wird einmal.

## [0.15.0] – 2026-10-20

### Neu
- **Markdown-Import und -Export** (#4): Ablage › Markdown importieren (Dateien oder ganze Ordner) und Als Markdown exportieren (⌥⌘E), auch für ganze Ordner über das Kontextmenü. Überschriften, Listen, Checklisten, Fett/Kursiv/Durchgestrichen, Links und Code-Fences bleiben erhalten; Mermaid wird zum Diagramm, `$$` zur Formel. Anhänge landen beim Export in einem Ordner „… Dateien“ neben der .md-Datei, Bilder werden beim Import übernommen.
- **Vorlagen** (#6): Seitenleiste › Vorlagen mit Startvorlagen für Meeting, Lernnotiz und Projekt. Vorlagen sind normale Notizen zum Bearbeiten; {{datum}}, {{uhrzeit}}, {{wochentag}} und {{kw}} werden beim Anlegen ersetzt. Neue Notiz aus Vorlage über das gedrückt gehaltene Neu-Symbol oder Ablage › Neu aus Vorlage; jede Notiz lässt sich als Vorlage sichern.
- **Notizlinks und Rückverweise** (#7): „[[“ tippen oder ⌥⌘K öffnet die Notizsuche und fügt einen Link ein. Links nutzen die feste Notiz-ID und funktionieren auch nach dem Umbenennen. Am Ende jeder Notiz stehen die Notizen, die auf sie verweisen. „Notizlink kopieren“ liefert folio://-Links, die auch aus anderen Apps öffnen.
- **Suche mit Filtern** (#8): Filter-Symbol in der Notizliste für Tags, Ordner, Zeitraum und Inhalt (Code, Bilder, PDFs, Audio, Formeln …), als Chips sichtbar und einzeln entfernbar. Auch tippbar: `tag:`, `ordner:`, `typ:`, `seit:`. Die Suche durchsucht standardmäßig die ganze Bibliothek; die einfache Suche funktioniert wie bisher.
- **Unterordner einbeziehen** (#17): Ein Ordner kann auf Wunsch auch die Notizen aller Unterordner zeigen (Ordner-Kontextmenü oder Filter).
- **Tags verwalten** (#18): Rechtsklick auf einen Tag: Umbenennen, Zusammenführen oder aus allen Notizen entfernen, mit Fortschritt und Liste der Fehler. Vor jeder Änderung wird eine Version gesichert.
- **Schnell öffnen** (#20): ⌘P öffnet eine Liste mit den zuletzt geöffneten Notizen zuerst und unscharfer Suche über alle Titel; ↑/↓ und ↩ reichen. Außerdem Ablage › Zuletzt geöffnet.

## [0.14.0] – 2026-10-20

### Neu
- **Versionsverlauf** (#1): Folio sichert beim Bearbeiten alle 5 Minuten eine Version, beim Öffnen den Ausgangsstand und immer, bevor etwas die Notiz ersetzt. Über das Uhr-Symbol oder Ablage › Versionsverlauf (⇧⌘Y) siehst du alle Stände mit Vergleich zum aktuellen und kannst einen wiederherstellen oder als neue Notiz sichern. Ältere Versionen werden ausgedünnt (stündlich, täglich, wöchentlich, max. ein Jahr).
- **Papierkorb** (#2): Gelöschte Notizen und Ordner landen in Folios eigenem Papierkorb (Seitenleiste) und lassen sich an ihren alten Ort zurückholen oder endgültig löschen. Nach 30 Tagen werden sie automatisch entfernt (einstellbar).
- **Konflikte erkennen** (#53): Ändert ein anderes Programm oder iCloud die offene Notiz, während du ungesicherte Änderungen hast, überschreibt Folio nichts. Ein Dialog zeigt die Unterschiede und bietet „Meine Version behalten“, „Geänderte Datei übernehmen“ oder „Beide behalten“. Ohne eigene Änderungen wird die neue Fassung einfach geladen.
- **Beschädigte Dateien** (#54): Statt einer Fehlermeldung zeigt Folio, was an der Datei kaputt ist (Prüfsumme, Kopf, Inhalt, Anhänge), und rettet den lesbaren Teil als neue Notiz oder stellt die letzte intakte Version wieder her. Das Original wird nie gelöscht. Unlesbare Dateien erscheinen unter „Beschädigt“ in der Seitenleiste; `folio-dump --check <Ordner>` prüft eine ganze Bibliothek.
- **Automatische Backups** (#55): Täglich (einstellbar) eine Zip-Sicherung der Bibliothek nach `~/Library/Application Support/Folio/Backups`, direkt nach dem Schreiben vollständig geprüft und rotierend ausgedünnt. Unter Einstellungen › Sicherheit: jetzt sichern, prüfen und als eigenen Ordner wiederherstellen, ohne vorhandene Notizen anzufassen.

## [0.13.1] – 2026-10-20

### Behoben
- Mermaid-Diagramme waren in der Formatleiste nicht zu finden: Formel, Diagramm und Audioaufnahme haben jetzt eigene Symbole (ƒ(x), Diagramm, Mikrofon). Im Menü Einfügen › Diagramm (Mermaid) gibt es zusätzlich das Kürzel ⌥⌘G.

## [0.13.0] – 2026-10-20

### Neu
- **PDF-Export** (#5): Ablage › Als PDF exportieren (⇧⌘E) schreibt die ganze Notiz als A4-PDF mit Seitenumbrüchen: Text mit Formatierung, Bilder, Zeichnungen, eingebettete PDFs, Code mit Syntaxfarben, Formeln und Diagramme als Vektorgrafik und Transkripte. Code-Ausgaben lassen sich im Sichern-Dialog ein- oder ausschließen.
- **Formelblock (LaTeX)** (#52): Formeln mit Live-Vorschau über KaTeX, Fehlermeldung bei falscher Syntax; Export als PNG/PDF oder in die Zwischenablage. Einfügen über das ƒ(x)-Symbol, ⌥⌘M oder ⌃⇧M.
- **Diagrammblock (Mermaid)** (#51): Flussdiagramme, Sequenzdiagramme usw. werden lokal gerendert, mit Syntaxfehlermeldung und Export als SVG, PNG oder PDF. Einfügen über Einfügen › Diagramm oder ⌃⇧G.
- **Audioaufnahmen** (#47): Aufnahme direkt in der Notiz (⌥⌘R oder ⌃⇧A) mit Pegelanzeige; danach abspielbar mit Wellenform zum Spulen, ±15 s und Geschwindigkeit. Audiodateien (m4a, mp3, wav …) lassen sich auch einfügen oder hineinziehen.
- **Lokale Transkription** (#48): Aufnahmen und Audiodateien werden auf dem Mac in Text umgewandelt (Sprache wählbar), ohne Upload. Das Transkript ist durchsuchbar und lässt sich mit einem Klick in die Notiz übernehmen.

## [0.12.4] – 2026-10-20

### Geändert
- Das Update-Fenster zeigt den Changelog aller neueren Versionen als formatiertes Markdown (Überschriften, Listen, Fett, Code).

### Behoben
- Update-Prüfung funktioniert auch, wenn das GitHub-API-Limit erreicht ist (Ausweichen auf die Release-Seite).

## [0.12.3] – 2026-10-20

### Behoben
- Update blieb nach der Installation hängen: Das offene Update-Fenster verhinderte, dass sich die alte Version beendet, deshalb startete die neue nie. Folio speichert jetzt selbst, schließt das Fenster und beendet sich sicher; die neue Version startet wenige Sekunden nach dem Download.

## [0.12.2] – 2026-10-20

### Geändert
- Update-Fenster mit Fortschrittsbalken über das ganze Update: Download mit MB und Prozent, danach Prüfen, Kopieren, Ersetzen und Neustart als eigene Schritte.

## [0.12.1] – 2026-10-20

### Geändert
- Folio sucht jetzt bei jedem Start nach einer neuen Version und fragt, ob sie installiert werden soll (Update-Fenster mit Änderungen). Gilt auch für bestehende Installationen; abschaltbar unter Einstellungen › Allgemein › Updates.

## [0.12.0] – 2026-10-20

### Hinzugefügt
- Software-Update (#64): „Nach Updates suchen …“ im Folio-Menü und unter Einstellungen › Allgemein vergleicht die installierte Version mit dem neuesten GitHub-Release, zeigt die Änderungen und installiert auf Knopfdruck: Download, Prüfung der App, alte Version in den Papierkorb, neue an dieselbe Stelle, Neustart. Notizen und Einstellungen bleiben unberührt. Optional automatische Prüfung beim Start.

## [0.11.0] – 2026-10-20

### Hinzugefügt
- Microsoft SQL Server im Datenbank-Block (über `sqlcmd`), inklusive Schema, Primärschlüsseln und Änderungszahlen; getestet gegen einen echten SQL Server in Docker.
- SQL-Codefelder können auf Datenbanken zugreifen: Im Kopf des Codefelds wählst du eine Verbindung (aus der Notiz oder alle bisher in Folio angelegten) oder legst eine neue an. ⇧↩ führt das SQL darauf aus, das Ergebnis erscheint als Tabelle, und die Vorschläge kennen die Tabellen und Spalten. Ohne Verbindung läuft SQL wie bisher in einer SQLite-Datenbank im Arbeitsspeicher.

## [0.10.0] – 2026-10-20

### Hinzugefügt
- Datenbank-Block wie in DataGrip: Verbindung zu SQLite, PostgreSQL und MySQL/MariaDB direkt in der Notiz (Zylinder-Symbol, Einfügen › Datenbank-Abfrage oder ⌃⇧D). Verbindungsdialog mit „Verbindung testen“, Passwörter im macOS-Schlüsselbund, Schema-Ansicht mit Tabellen, Spalten, Typen und Primärschlüsseln (Doppelklick zeigt den Inhalt), SQL-Feld mit Hervorhebung und Vorschlägen für Tabellen- und Spaltennamen, Ausführen mit ⇧↩, Ergebnistabelle mit Zeilennummern und NULL-Anzeige, Ergebnis als CSV kopieren. Nutzt die installierten Clients sqlite3, psql und mysql.

## [0.9.0] – 2026-10-20

### Hinzugefügt
- Neuer Tab „Feedback“ in den Einstellungen: Er öffnet die Issues-Seite von Folio auf GitHub, wahlweise mit einem neuen Eintrag, in dem App- und macOS-Version schon stehen.

## [0.8.2] – 2026-10-20

### Behoben
- Die Popup-Animation des KI-Chats lief nicht: Die Sichtbarkeit hing an einer gespeicherten Einstellung, deren Änderung außerhalb der Animation ankommt. Das Panel wird jetzt eingefügt und danach in einem eigenen Schritt aus dem ✨-Knopf herausgefedert (und vor dem Entfernen dorthin zurückgeschrumpft).

## [0.8.1] – 2026-10-20

### Geändert
- Der KI-Chat öffnet sich mit einer Popup-Animation: Das Panel federt aus dem ✨-Knopf oben rechts heraus und schrumpft beim Schließen dorthin zurück.

## [0.8.0] – 2026-10-20

### Hinzugefügt
- Dezente Animationen: Blöcke erscheinen und verschwinden weich, die Notizliste ordnet sich animiert um, Auswahl und Hover blenden über, Ausgabe und Server-Leiste gleiten ein, Vorschlagsliste und KI-Chat blenden ein, Wechsel zwischen Notizen und das Ein-/Ausblenden der Seitenleiste sind animiert. Schalter unter Einstellungen › Darstellung; mit „Bewegung reduzieren“ in den Systemeinstellungen bleiben sie aus.

## [0.7.1] – 2026-10-20

### Behoben
- Gelöschte Code-Blöcke lebten in der gemeinsamen Sitzung weiter (z. B. blieb `a` nach dem Löschen von `a = 10` verfügbar). Beim Löschen wird die Sitzung jetzt neu gestartet, die übrigen verknüpften Blöcke werden im Hintergrund neu ausgeführt (außer Server), und ein laufender Block wird gestoppt.

### Hinzugefügt
- `make regression`: automatische App-Prüfungen mit einer Test-Bibliothek (u. a. gelöschte und verknüpfte Code-Blöcke).

## [0.7.0] – 2026-10-19

### Hinzugefügt
- ⇧↩ führt den Code-Block aus (zusätzlich zu ⌘↩), neue Code-Blöcke bekommen sofort den Cursor.
- Tastenkürzel für Werkzeuge: ⌃C Code-Block, ⌃T Numbers-Tabelle, ⌃D Zeichnung, ⌃L Checkliste, ⌃W Webseite, ⌃I Datei/Bild/PDF, ⌃G Image Playground, ⌃U Link, ⌃J KI-Chat, ⌃R Writing Tools, ⌃⇧R alle Code-Blöcke ausführen. In einem laufenden Code-Block stoppt ⌃C die Ausführung.
- Einstellungen › Tastenkürzel: alle Kürzel auf einen Blick, Werkzeug-Kürzel neu belegen, entfernen oder zurücksetzen, Warnung bei Doppelbelegung.

## [0.6.0] – 2026-10-19

### Hinzugefügt
- Verknüpfte Code-Blöcke wie in einem Notebook: Blöcke derselben Sprache in einer Notiz teilen sich eine laufende Sitzung (Python, JavaScript, Ruby, Bash, Zsh), z. B. `a = 10` in einem Block und `print(a)` im nächsten. Der letzte Ausdruck eines Blocks wird wie in einer REPL angezeigt. Im Code-Kopf: Sitzungsanzeige, „Alle Code-Blöcke ausführen“, „Sitzung neu starten“ und Verknüpfung pro Block abschaltbar. Stoppen unterbricht nur den laufenden Code, Variablen bleiben. Die Sitzung endet beim Schließen der Notiz oder der App.
- Autovervollständigung kennt Variablen aus verknüpften Blöcken und fragt die laufende Sitzung nach ihren Namen.
- Die aktuelle Version steht unten im Einstellungsfenster.

## [0.5.1] – 2026-10-19

### Behoben
- Autovervollständigung: Schnelles Weitertippen und Enter übernahm einen veralteten Vorschlag (z. B. `System.out.flush()` statt `println`). Die Liste wird jetzt sofort mit jedem Zeichen gefiltert, und nur noch passende Einträge werden übernommen.
- In die Notiz eingefügte KI-Antworten zeigen `Code` als Code statt mit Backticks und behalten verschachtelte Listen bei.
- Die Vorschlagsliste folgt dem hellen bzw. dunklen Modus der App und schneidet keine halbe Zeile mehr an.

## [0.5.0] – 2026-10-19

### Hinzugefügt
- KI-Chat mit Apple Intelligence (auf dem Gerät): schwebendes Panel neben der Notiz (✨ in der Aktionsleiste, ⌥⌘I), kennt die Notiz und auf Wunsch die Auswahl, antwortet live, Schnellaktionen (Zusammenfassen, Stichpunkte, Aufgaben, Fragen, Übersetzen), Antworten lassen sich in die Notiz einfügen oder kopieren; eine Unterhaltung pro Notiz.

### Geändert
- Text- und Code-Vorhersagen erscheinen schneller: Das Sprachmodell wird beim Start vorgeladen, jede Anfrage startet mit einer vorbereiteten Sitzung, kürzere Wartezeit nach dem Tippen, weniger Kontext und ein Cache. Gemessen: erste Vorhersage 1,1 s statt ca. 3,6 s, danach 0,86 s statt ca. 1,25 s.

## [0.4.0] – 2026-10-19

### Hinzugefügt
- IDE-Autovervollständigung in Codefeldern: Vorschlagsliste mit Methoden, Feldern, Klassen und Modulen nach `.`, `::`, `->`, ab zwei Buchstaben oder mit ⌃Leertaste; ↑/↓, Enter/Tab, Esc. Quellen: installierte Sprachserver (sourcekit-lsp, clangd, rust-analyzer, gopls, pyright, typescript-language-server, jdtls …), sonst Introspektion über Python, `javap` (Java) und Node.js, sonst Schlüsselwörter und Wörter im Code. Übersicht und Schalter in den Einstellungen › Code.

## [0.3.1] – 2026-10-19

### Behoben
- Kann eine lokale Seite nicht geladen werden, bietet die Fehlermeldung keine (leere) Link-Vorschau mehr an.

## [0.3.0] – 2026-10-19

### Hinzugefügt
- Apple Intelligence Writing Tools in Notizen: Umschreiben, Korrekturlesen, Zusammenfassen, Listen und Tabellen (Formatleiste, Format-Menü, ⇧⌘W, Kontextmenü).
- Code-Vorhersage in Codefeldern mit Apple Intelligence: graue Vorschläge passend zur Sprache, Tab übernimmt, Esc verwirft; abschaltbar in den Einstellungen.
- Auto-Formatierung im Codefeld: Klammern und Anführungszeichen schließen sich, Enter rückt passend ein (auch zwischen `{}`), schließende Klammern rücken aus, Backspace entfernt ganze Einrückungen, Tabs oder Leerzeichen je nach Sprache.
- „Code formatieren“ (⌥⇧F) mit installiertem Formatierer (ruff/black, prettier, swift-format, gofmt, rustfmt, clang-format, shfmt …), sonst eigenes Neu-Einrücken.

## [0.2.0] – 2026-10-19

### Hinzugefügt
- Codeblöcke erkennen Server (an der Ausgabe oder einem offenen Port): kein Abbruch nach dem Zeitlimit, Live-Ausgabe, „Stoppen“ beendet auch Unterprozesse, die Seite lässt sich direkt in der Notiz öffnen.

### Behoben
- Lokale Adressen ohne `http://` (z. B. `localhost:3000`, `192.168.1.5:8080`) werden beim Einbetten und Einfügen als `http`-Seite geöffnet statt per `https`.
- Lokale Seiten werden immer als Webseite dargestellt, nie als leere Link-Vorschau.

## [0.1.0] – 2026-10-19

Erste veröffentlichte Version für Apple Silicon (macOS 15.2 oder neuer).

### Hinzugefügt
- Bibliothek aus einzelnen `.folio`-Dateien mit echten Ordnern, Suche, angehefteten Notizen und `#tags`.
- Rich-Text-Editor mit Formatleiste, Codeblöcke mit Syntaxhervorhebung und Ausführung über lokale Interpreter.
- Eingebettete PDFs, Bilder, Dokumente und live dargestellte Webseiten, auch aus dem lokalen Netz (localhost).
- Zeichenblöcke mit PencilKit sowie Skizze, Foto oder Scan vom iPhone/iPad per Continuity Camera.
- Bilder per Drag & Drop und ⌘V einfügen, auch ohne aktives Textfeld.
- Textvorhersage mit Apple Intelligence (Foundation Models auf dem Gerät), abschaltbar in den Einstellungen.
- Import aus Apple Notizen inklusive verschachtelter Ordner.
- Oberfläche mit schwebenden Panels, eigenen Fensterknöpfen, Akzentfarben, hellem und dunklem Modus.
- Installer: DMG mit Programme-Verknüpfung und PKG (`make installer`).

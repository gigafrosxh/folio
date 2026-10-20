# Barrierefreiheit (VoiceOver-Audit, #60)

Stand: Folio 0.19.0.

## Was geprüft wird

`python3 scripts/dev-regression.py` startet Folio mit einer Testnotiz, die alle Blockarten enthält, und lässt
`AccessibilityAudit` (`FOLIO_A11Y_AUDIT=1`) den Zugänglichkeitsbaum aller Fenster durchgehen. Jedes Bedienelement
(Knopf, Menüknopf, Schalter, Textfeld …) braucht einen Namen, den VoiceOver vorlesen kann. Der Lauf schlägt fehl,
sobald eines fehlt. Bildlaufleisten-Teile benennt macOS selbst und werden übersprungen.

Ergebnis 0.19.0: **0 Bedienelemente ohne Namen.** SwiftUI baut den Baum nur teilweise auf, solange kein echtes
Hilfsprogramm verbunden ist; der Audit sieht deshalb nicht jedes Element einer langen Notiz.

## Was in 0.19 verbessert wurde

- Alle Symbolknöpfe (Formatleiste, Notiz-Aktionen, Code-Block, Zeichnen, Datenbank, Terminal, Tabs, KI-Chat,
  Suchleiste) haben einen gesprochenen Namen. Er kommt aus dem Tooltip ohne Tastenkürzel und Zusatzerklärung
  (`helpLabel(_:)` in `Views/Accessibility.swift`), z. B. „Fett (⌘B)“ → „Fett“.
- Menüknöpfe mit Symbol (Code-Block, Zeichnen, Terminal) werden als „Code-Block einfügen“ usw. vorgelesen.
- Seitenleisten-Einträge, Notizkarten und Tabs sind für VoiceOver Knöpfe mit Auswahlzustand; Notizkarten haben die
  zusätzlichen Aktionen „In neuem Tab öffnen“ und „Rechts daneben öffnen“ (VoiceOver-Rotor › Aktionen).
- Die Seitenleiste nennt die Anzahl der Notizen je Eintrag.

## Kontrast und Farben

Texte nutzen die Systemfarben (`primary`, `secondary`, `textColor`), die macOS bei „Kontrast erhöhen“ selbst
anpasst; Hell- und Dunkelmodus folgen dem System. Hinweise mit Farbe (Fehlerzeilen, Konflikte, Speicherwarnungen)
haben immer auch Text oder ein Symbol.

## Tastatur

Alle Werkzeuge haben Menüeinträge mit Kürzel, die Werkzeug-Kürzel (⌃…) lassen sich in den Einstellungen ändern.
`FOLIO_KEY_TEST=1` (#59) prüft die wichtigsten Kürzel automatisch und dass kein Menükürzel doppelt belegt ist.

## Offen

- Eine Prüfung mit eingeschaltetem VoiceOver durch einen Menschen (Fokusreihenfolge in langen Notizen, Vorlesen
  von Formeln und Diagrammen) steht aus.
- Formeln und Diagramme sind Webansichten; VoiceOver liest dort den gerenderten Inhalt, nicht den Quelltext.

# Komplexitätsprüfung

Folio misst die kognitive Komplexität jeder Swift-Funktion mit dem Werkzeug in `Tools/ComplexityCheck` (#156). Es liest den
Syntaxbaum mit [SwiftSyntax](https://github.com/swiftlang/swift-syntax), statt Text mit regulären Ausdrücken zu durchsuchen. Lokal
und im CI ergibt derselbe Commit dieselben Zahlen, weil Dateien sortiert gelesen werden und nur der Quelltext zählt.

```sh
swift run -c release --package-path Tools/ComplexityCheck complexity-check \
  --baseline Tools/ComplexityCheck/baseline.json --report complexity.md --json complexity.json Sources
```

## Was gemessen wird

- **Einheiten:** Methoden und freie Funktionen, Initializer, berechnete Properties (auch `body` von SwiftUI-Ansichten) und
  Subscripts. Gespeicherte Properties mit `willSet`/`didSet` zählen nicht. Verschachtelte Funktionen gehören zu ihrer Funktion.
- **Ausgeschlossen:** alles außerhalb von `Sources`, also Tests, Fixtures, Skripte, das gebündelte KaTeX/Mermaid und `.build`.
- **Punkte:**
  - +1 für `if`, `else if`, `else`, `guard`, `switch`, `for`, `while`, `repeat`, `catch`, den ternären Operator und `break`/`continue` mit Label.
  - +1 für jeden Wechsel zwischen `&&` und `||` in einer Kette (`a && b && c` zählt 1, `a && b || c` zählt 2).
  - `if`, `switch`, Schleifen, `catch` und der ternäre Operator zählen zusätzlich die aktuelle Verschachtelungstiefe.
  - Closures und verschachtelte Funktionen erhöhen die Tiefe, zählen selbst aber nicht.
  - `guard` erhöht die Tiefe nie, weil sein Körper den Bereich verlässt.
  - SwiftUI-`ViewBuilder` werden wie normaler Code gezählt: Ein `if` in einem `body` ist ein `if`.
- **Anzeige:** Der Rohwert wird auf 1–100 begrenzt. Im JSON-Bericht steht zusätzlich der unbegrenzte Rohwert (`raw`).

## Grenzwert und Baseline

Mehr als **15 Punkte** gelten als zu komplex. Bestehende Schulden stehen in `Tools/ComplexityCheck/baseline.json`
(Datei und Symbol, ohne Zeilennummer, damit Verschiebungen nicht stören). Das CI schlägt fehl, wenn eine Einheit **neu** über 15
liegt oder **schlechter** wird als in der Baseline. Wird eine Einheit verbessert, meldet der Bericht sie als erledigt; danach die
Baseline neu schreiben:

```sh
swift run -c release --package-path Tools/ComplexityCheck complexity-check \
  --baseline Tools/ComplexityCheck/baseline.json --update-baseline Sources
```

Die Baseline nur verkleinern. Eine neue Ausnahme braucht einen Grund im Commit, etwa eine Tabelle von Fällen, die als `switch` am
lesbarsten bleibt.

## Beispiel

```swift
func label(for count: Int, hidden: Bool) -> String {   // Punkte
    guard !hidden else { return "" }                      // +1 guard
    if count == 0 {                                       // +1 if
        return "leer"
    } else if count == 1 && !hidden {                     // +1 else if, +1 &&
        return "eins"
    }
    return items.map { $0 > 0 ? "+" : "-" }.joined()      // +2 Ternär in einer Closure (Tiefe 1)
}                                                         // = 6
```

## Abgleich mit der ersten Messung

Die Refactoring-Issues #138–#155 beruhten auf einer heuristischen Erstbewertung von Commit `c5858c1` (57 von 1.646 Einheiten über 15).
Die AST-Messung von Version 1.3.7 zählt 1.933 Einheiten. Alle in #138–#149, #150, #151, #152 und #153 genannten Einheiten liegen jetzt bei
höchstens 15. Weiter über dem Grenzwert stehen 50 Einheiten, fast alle SwiftUI-`body`-Properties, die die Erstbewertung niedriger
eingeschätzt hatte. Sie stehen in der Baseline. Mit 1.3.8 sind auch die Einheiten aus #154 und #155 unter dem Grenzwert; die Baseline hat danach 47 Einträge.

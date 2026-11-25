# Rust-Kern für Parsen und Rendern? – Bewertung (#391)

Stand 24.11.2026, Folio 1.11.27, Mac mini M4, Release-Build, Kopie der echten Bibliothek und synthetische Notizen
(`FOLIO_SWITCH_BENCH=1` bzw. `=synthetic`, `scripts/benchmark.sh`). Ergebnis: **No-Go** für einen Rust-Kern zum jetzigen
Zeitpunkt.

## Wo die Zeit beim Öffnen hingeht

| Messung | Zeit | Anteil Lesen/Entpacken/Dekodieren |
| --- | --- | --- |
| Notiz aus der echten Bibliothek wechseln (vor 1.11.26) | 535 ms | < 1 ms |
| Notiz mit 1000 Textblöcken öffnen (vor 1.11.27) | 2,5 s | ca. 1 % (22 von ~3000 Samples im Hauptthread) |
| Notiz mit 20 Formeln/Diagrammen öffnen (vor 1.11.27) | 1,8 s | < 1 %; Rest: WKWebView-Start, SwiftUI-Layout |
| Notiz mit 50-MB-Anhang öffnen (vor 1.11.27) | 1,2 s | rund ein Viertel (Lesen, CRC, LZFSE) |
| `folio-bench` notiz-lesen (1.000 Notizen) | 0,11 ms je Notiz | 100 % |
| `folio-bench` Bibliothek scannen, warm (1.000 Notizen) | ~100 ms | 100 % |

Die Profile (Hauptthread, `sample`) zeigen: Fast die ganze Wartezeit lag in SwiftUI/AppKit – die Editor-Kopfleiste
baute sieben Werkzeugleisten-Varianten (#392), hunderte `NSTextView`s samt Frame-Benachrichtigungen, eine quadratische
Falt-Berechnung, eine `WKWebView` pro Formel. Genau diese Stellen sind in 1.11.26/1.11.27 behoben (Notizwechsel 61 ms,
1000 Blöcke 0,16 s, 20 Formeln/Diagramme 0,25 s, 50-MB-Anhang ohne Blockade des Hauptthreads).

## Warum kein Rust

- **Obergrenze des Gewinns:** Selbst ein unendlich schneller Rust-Parser spart beim Öffnen höchstens den Anteil
  „Lesen/Entpacken/Dekodieren“ – in typischen Notizen unter 1–2 %. Rust beschleunigt nicht `NSTextView`, `WKWebView` oder
  SwiftUI-Layout, und genau dort lag die Zeit.
- **Entpacken ist schon nativ:** LZFSE kommt aus Apples `Compression`-Framework (C), JSON aus Foundation. Ein Rust-Kern
  müsste dieselben Formate lesen und bräuchte dafür eigene Bibliotheken.
- **Kosten:** C-ABI/FFI mit Speicher-Ownership, Panics, Abbruch; zweite Toolchain in CI, Release, Signieren und Notarisieren
  (#63); Universal-Builds; zwei Implementierungen des Dateiformats, die nie auseinanderlaufen dürfen.
- **Große Anhänge** sind jetzt aus dem Hauptthread genommen (#388); was bleibt, ist Datei-I/O, das keine Sprache
  schneller macht.

Ein Rust-Prototyp wurde deshalb nicht gebaut: Bei dieser Verteilung kann er die Nutzerzeit nicht messbar senken.

## Wann neu bewerten

- Wenn ein Profil zeigt, dass reine Rechenarbeit im Kern (Parsen, Suchindex, Graph-Layout, Diff) mehr als ~20 % einer
  spürbaren Wartezeit ausmacht.
- Wenn Folio Plattformen ohne Swift-Laufzeit braucht (z. B. ein Server oder Windows/Linux-Client) – dann als gemeinsamer
  Kern mit klarer FFI-Grenze, siehe `docs/PLATFORMS.md`.
- Vorgehen dann wie in #391 beschrieben: eine reine Funktion, Swift-Referenz parallel, gleiche Tests und Fuzzing,
  End-to-End-Messung inklusive FFI.

Messwerkzeuge: `FOLIO_SWITCH_BENCH=1` (Notiz-/Ordnerwechsel mit der Bibliothek in `FOLIO_LIBRARY`),
`FOLIO_SWITCH_BENCH=synthetic` (große Notizen), `scripts/benchmark.sh`, `docs/PERFORMANCE.md`.

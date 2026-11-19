# Performance messen (#219)

`scripts/benchmark.sh [100,1000,10000]` erzeugt deterministische, rein synthetische Bibliotheken (gleicher Seed, gleiche
Notizen) in einem temporären Ordner und misst:

- **Kern** (`folio-bench`): Bibliotheks-Scan kalt/warm, Suche (Filter, unscharf), Link-Index, Graph-Layout, Notiz lesen,
  Code-Completion-Kontext, Syntax-Tokens, Färbungs-Diff, Code-Abhängigkeiten, Zeilen-Diff (1k/10k/100k Zeichen).
- **App** (`FOLIO_BENCH`, im Hintergrund ohne Fenster und Fokus): Neuladen der Bibliothek auf dem Hauptthread, gefilterte
  Liste, Notiz öffnen, Tippen in 2000 Absätzen Text und 3000 Zeilen Code (echte Textansichten mit Layout und Höhe).

Jeder Wert ist Median und p95 aus mehreren Läufen (nach einem Aufwärmlauf; „kalt“ ohne). Der Bericht (`bench/…json`,
`.csv`) enthält Commit, macOS, Modell, Kerne und Speicher, aber keine Nutzerdaten. Laufzeiten sind kein hartes CI-Gate.

## Ausgangswerte (19.11.2026, Mac mit 10 Kernen, Release-Build)

| Szenario | 1.000 Notizen | 10.000 Notizen |
| --- | --- | --- |
| Bibliothek scannen, kalt | 62 ms | 691 ms |
| Bibliothek scannen, warm | 54 ms | 613 ms |
| Neuladen in der App (Hauptthread) | 95 ms | – |
| Suche mit Filter | 0,4 ms | 4 ms |
| Unscharfe Suche | 4,4 ms | 45 ms |
| Link-Index | 1,4 ms | 14 ms |
| Graph-Layout (150 Schritte) | 119 ms | – |

| Editor | vorher | nachher |
| --- | --- | --- |
| Tippen in 2000 Absätzen Text | 1,4 ms | 1,4 ms |
| Tippen in 3000 Zeilen Code | 55,6 ms | 18 ms (#221: nur geänderte Zeilen neu färben) |
| Completion-Kontext, 100k Zeichen | 1,96 ms | 0,03 ms (#222: Zeilen zählen statt teilen) |

| Neuladen der Bibliothek, 1.000 Notizen | vorher | nachher |
| --- | --- | --- |
| synchron (Start, Aktionen, die gleich danach auf die Liste zugreifen) | 95 ms | 55 ms |
| im Hintergrund, Anteil auf dem Hauptthread („Neu laden“, Bibliothek wechseln) | 95 ms | 2,3 ms |

Beim Neuladen kosteten vor allem die Prüfung auf doppelte Notiz-IDs (Pfade vergleichen für jede Notiz) und die Ordnernamen
für den Link-Index auf dem Hauptthread Zeit (#220). Das Lesen der Dateien läuft jetzt im Hintergrund; nur der neueste
Lesevorgang wird übernommen.

Folgerungen: Das synchrone Neuladen wächst weiter linear mit der Bibliotheksgröße, wird aber nur noch beim Start und dort
gebraucht, wo eine Aktion die Liste sofort braucht. Im Code-Editor kostet jetzt
vor allem das Zerlegen des ganzen Blocks in Tokens (15 ms bei 100k Zeichen).

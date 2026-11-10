import Foundation

/// Compares the measured units with the limit and the baseline of known debt (#156).
public struct ComplexityReport {
    public static let limit = 15

    public var units: [Unit]
    /// Known units over the limit and their score when the baseline was written.
    public var baseline: [String: Int]

    public init(units: [Unit], baseline: [String: Int]) {
        self.units = units
        self.baseline = baseline
    }

    public var overLimit: [Unit] { units.filter { $0.score > Self.limit }.sorted { ($0.score, $1.file) > ($1.score, $0.file) } }

    /// New units over the limit, or known ones that got worse: these fail the check.
    public var violations: [Unit] {
        overLimit.filter { unit in baseline[unit.key].map { unit.score > $0 } ?? true }
    }

    /// Baseline entries that are now within the limit or gone, so the baseline can shrink.
    public var resolved: [String] {
        let over = Dictionary(overLimit.map { ($0.key, $0.score) }, uniquingKeysWith: max)
        return baseline.keys.filter { over[$0] == nil }.sorted()
    }

    public var newBaseline: [String: Int] { Dictionary(overLimit.map { ($0.key, $0.score) }, uniquingKeysWith: max) }

    /// How many units fall into each score band.
    public var distribution: [(band: String, count: Int)] {
        let bands = [("1–5", 1...5), ("6–10", 6...10), ("11–15", 11...15), ("16–30", 16...30), ("31–100", 31...100)]
        return bands.map { name, range in (name, units.filter { range.contains($0.score) }.count) }
    }

    public var markdown: String {
        var lines = ["# Komplexitätsbericht", "",
                     "Geprüft: \(units.count) Einheiten (\(count(.method)) Methoden/Funktionen, \(count(.initializer)) Initializer, \(count(.property)) berechnete Properties). Grenzwert: \(Self.limit).", "",
                     "| Punkte | Einheiten |", "|---|---:|"]
        lines += distribution.map { "| \($0.band) | \($0.count) |" }
        lines += ["", "## Über dem Grenzwert (\(overLimit.count))", "", "| Datei | Zeile | Symbol | Art | Punkte | Rohwert | Baseline |", "|---|---:|---|---|---:|---:|---:|"]
        lines += overLimit.map { u in
            "| \(u.file) | \(u.line) | `\(u.symbol)` | \(u.kind.rawValue) | \(u.score) | \(u.raw) | \(baseline[u.key].map(String.init) ?? "neu") |"
        }
        if !violations.isEmpty { lines += ["", "## Fehler: neu oder verschlechtert (\(violations.count))", ""] + violations.map { "- `\($0.symbol)` (\($0.file):\($0.line)): \($0.score)" } }
        if !resolved.isEmpty { lines += ["", "## Aus der Baseline erledigt (\(resolved.count))", ""] + resolved.map { "- \($0)" } }
        return lines.joined(separator: "\n") + "\n"
    }

    private func count(_ kind: Unit.Kind) -> Int { units.filter { $0.kind == kind }.count }
}

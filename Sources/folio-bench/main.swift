import Foundation
import FolioCore

// Benchmarks of the core on synthetic libraries (#219). Usage: folio-bench <work folder> <report.json> [sizes] [commit]
// The work folder must be empty or new; it is filled with generated notes and never a real library.

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("Aufruf: folio-bench <leerer Arbeitsordner> <bericht.json> [Größen, z. B. 100,1000,10000] [Commit]")
    exit(2)
}
let work = URL(fileURLWithPath: args[1], isDirectory: true)
let report = URL(fileURLWithPath: args[2])
let sizes = (args.count > 3 ? args[3] : "100,1000,10000").split(separator: ",").compactMap { Int($0) }
let commit = args.count > 4 ? args[4] : "unbekannt"
if let existing = try? FileManager.default.contentsOfDirectory(atPath: work.path), !existing.isEmpty {
    print("Der Arbeitsordner muss leer sein: \(work.path)")
    exit(2)
}

var results: [Benchmark.Result] = []
func record(_ r: Benchmark.Result) {
    results.append(r)
    print(String(format: "%-34@ %6d  median %9.2f ms  p95 %9.2f ms", r.scenario as NSString, r.size, r.medianMs, r.p95Ms))
}

for size in sizes {
    let root = work.appendingPathComponent("bibliothek-\(size)", isDirectory: true)
    let start = Date()
    try Benchmark.generateLibrary(at: root, count: size)
    print("Bibliothek mit \(size) Notizen erzeugt (\(Int(Date().timeIntervalSince(start)))) s")
    let runs = size >= 10_000 ? 3 : 7

    record(Benchmark.measure("bibliothek-scan-kalt", size: size, runs: runs, cold: true) { _ = LibraryScanner().scan(root) })
    let scanner = LibraryScanner()
    let scanned = scanner.scan(root)
    record(Benchmark.measure("bibliothek-scan-warm", size: size, runs: runs) { _ = scanner.scan(root) })

    let metas = scanned.notes.map(\.meta)
    let filter = SearchFilter(text: "analyse budget", tags: ["thema3"])
    record(
        Benchmark.measure("suche-filter", size: size, runs: runs) {
            _ = metas.filter { filter.matches($0, folderPath: "") }
        })
    record(
        Benchmark.measure("suche-unscharf", size: size, runs: runs) {
            _ = FuzzyMatch.rank(metas, query: "notiz 42 plan") { $0.title + " " + $0.preview }
        })
    let pairs = scanned.notes.map { (meta: $0.meta, folder: $0.url.deletingLastPathComponent().lastPathComponent) }
    record(Benchmark.measure("linkindex-aufbau", size: size, runs: runs) { _ = LinkIndex(pairs) })
    if size <= 1000 {
        let index = LinkIndex(pairs)
        let nodes = scanned.notes.map(\.meta.id)
        let edges = index.edges()
        record(Benchmark.measure("graph-layout", size: size, runs: 3) { _ = GraphLayout.compute(nodes: nodes, edges: edges, iterations: 150) })
    }
    if let first = scanned.notes.first?.url {
        record(Benchmark.measure("notiz-lesen", size: size, runs: runs) { _ = try? NoteFile.read(from: first) })
    }
}

// Editor-near work that does not need the app: completion context and diffs on long code (#221, #222).
for chars in [1_000, 10_000, 100_000] {
    let line = "wert = berechne(daten, faktor) + 1\n"
    let code = String(repeating: line, count: chars / line.count)
    record(
        Benchmark.measure("completion-kontext", size: chars) {
            _ = CompletionContext(code: code, offset: (code as NSString).length - 5, language: "python")
        })
    record(
        Benchmark.measure("code-abhaengigkeiten", size: chars) {
            _ = CodeDependencies.build([.init(id: UUID(), language: "python", session: "python", code: code, lastRun: nil)])
        })
    let py = Languages.spec(for: "python")
    let tokens = SyntaxHighlighter.tokens(in: code, language: py)
    record(Benchmark.measure("syntax-tokens", size: chars) { _ = SyntaxHighlighter.tokens(in: code, language: py) })
    let typed = code + "x"
    record(
        Benchmark.measure("highlight-diff", size: chars) {
            _ = HighlightDiff.span(oldText: code as NSString, newText: typed as NSString, oldTokens: tokens, newTokens: tokens)
        })
    record(
        Benchmark.measure("zeilen-diff", size: chars, runs: 3) {
            _ = LineDiff.diff(old: code, new: code.replacingOccurrences(of: "faktor", with: "faktor2"))
        })
}

let rep = Benchmark.Report(commit: commit, results: results)
try rep.json().write(to: report)
try rep.csv().write(to: report.deletingPathExtension().appendingPathExtension("csv"), atomically: true, encoding: .utf8)
print("Bericht: \(report.path)")

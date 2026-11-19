import AppKit
import FolioCore

/// App-side benchmarks (#219), FOLIO_BENCH=<report.json> with FOLIO_LIBRARY pointing to an empty folder: generates a
/// synthetic library there and measures what runs on the main thread – reload, opening notes and typing in long
/// text and code blocks (#220, #221, #222). Never touches a real library.
@MainActor
enum AppBenchmark {
    /// Main-thread time of the last applied background reload, measured inside NoteStore.
    static var lastApplyMs: Double { NoteStore.shared.lastApplyMs }

    static func run(report: URL) async {
        let env = ProcessInfo.processInfo.environment
        guard let lib = env["FOLIO_LIBRARY"] else { return }
        let size = Int(env["FOLIO_BENCH_SIZE"] ?? "1000") ?? 1000
        let store = NoteStore.shared
        if store.notes.isEmpty {
            try? Benchmark.generateLibrary(at: URL(fileURLWithPath: lib), count: size) {
                RichTextCodec.rtfData(from: NSAttributedString(string: $0, attributes: ThemeManager.shared.bodyAttributes))
            }
            store.reload()
        }
        var results: [Benchmark.Result] = []
        func record(_ r: Benchmark.Result) {
            results.append(r)
            print(String(format: "BENCH %@ %d median %.2f ms p95 %.2f ms", r.scenario, r.size, r.medianMs, r.p95Ms))
            fflush(stdout)
        }
        record(Benchmark.measure("app-reload-mainthread", size: store.notes.count, runs: 5) { store.reload() })
        // Background reload: only applying the result runs on the main thread (#220).
        var applyTimes: [Double] = []
        for _ in 0..<5 {
            let t = store.reloadInBackground()
            await t.value
            applyTimes.append(lastApplyMs)
        }
        applyTimes.sort()
        record(
            Benchmark.Result(
                scenario: "app-reload-hintergrund-hauptthreadanteil", size: store.notes.count, runs: 5,
                medianMs: applyTimes[2], p95Ms: applyTimes[4], minMs: applyTimes[0], peakMemoryMB: Benchmark.peakMemoryMB()))
        record(Benchmark.measure("app-suche-gefiltert", size: store.notes.count, runs: 5) { _ = store.computeFilteredNotes() })
        let ids = Array(store.notes.prefix(20).map(\.id))
        var i = 0
        record(
            Benchmark.measure("app-notiz-oeffnen", size: ids.count, runs: 20) {
                store.open(noteID: ids[i % ids.count])
                i += 1
            })
        await typing(store: store, record: record)
        let rep = Benchmark.Report(commit: env["FOLIO_BENCH_COMMIT"] ?? "unbekannt", results: results)
        try? rep.json().write(to: report)
        print("BENCH done")
        fflush(stdout)
    }

    /// Typing at the end of a long text and a long code block, through the real text views (layout and height).
    private static func typing(store: NoteStore, record: (Benchmark.Result) -> Void) async {
        guard store.createNote() != nil, let doc = store.currentDocument else { return }
        let theme = ThemeManager.shared
        let paragraphs = (0..<2000).map { "Absatz \($0) mit etwas Text, der in der Zeile umbricht, wenn das Fenster schmal ist." }
        doc.blocks[0].storage.setAttributedString(NSAttributedString(string: paragraphs.joined(separator: "\n"), attributes: theme.bodyAttributes))
        let code = BlockModel(kind: .code)
        code.storage.setAttributedString(NSAttributedString(string: (0..<3000).map { "wert_\($0) = berechne(daten, \($0))" }.joined(separator: "\n")))
        doc.insert(code, after: doc.blocks[0].id)
        doc.markDirty()
        try? await Task.sleep(for: .seconds(1.5))
        if let tv = FormattingController.shared.textView(for: doc.blocks[0].id) {
            tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
            record(Benchmark.measure("app-tippen-text-2000-absaetze", size: 2000, runs: 30) { tv.insertText("x", replacementRange: tv.selectedRange()) })
        } else {
            print("BENCH skip Text (keine Ansicht)")
        }
        if let cv = FormattingController.shared.codeView(for: code.id) {
            cv.setSelectedRange(NSRange(location: cv.string.utf16.count, length: 0))
            record(Benchmark.measure("app-tippen-code-3000-zeilen", size: 3000, runs: 30) { cv.insertText("x", replacementRange: cv.selectedRange()) })
        } else {
            print("BENCH skip Code (keine Ansicht)")
        }
    }
}

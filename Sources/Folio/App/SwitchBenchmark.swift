import AppKit
import FolioCore

/// FOLIO_SWITCH_BENCH=1 with a throwaway FOLIO_LIBRARY: how long selecting notes and folders takes until the window has
/// laid itself out again (#388). Prints `SWITCH note|folder median … ms max … ms` and `SWITCH done`.
@MainActor
enum SwitchBenchmark {
    static func settle() {
        for window in NSApp.windows where window.isVisible {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    static func measure(_ change: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        change()
        settle()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// Synthetic notes for #388–#390: many text blocks, many diagrams and formulas, a large attachment.
    static func makeSyntheticNotes(in root: URL) -> [(String, URL)] {
        let theme = ThemeManager.shared
        func text(_ s: String) -> BlockRecord {
            var b = BlockRecord(kind: .text)
            b.rtf = RichTextCodec.rtfData(from: NSAttributedString(string: s, attributes: theme.bodyAttributes))
            return b
        }
        var out: [(String, URL)] = []
        func write(_ name: String, _ blocks: [BlockRecord], _ attachments: [FolioArchive.Attachment] = []) {
            let url = root.appendingPathComponent("Bench-\(name).folio")
            var file = NoteFile(meta: NoteMetadata(title: name), body: NoteBody(blocks: blocks), attachments: attachments)
            file.meta.title = name
            if (try? file.write(to: url)) != nil { out.append((name, url)) }
        }
        write("text-1000", [text("Viele Blöcke")] + (0..<1000).map { text("Absatz \($0) mit etwas Text, damit er eine Zeile füllt.") })
        let diagrams = (0..<10).flatMap { i -> [BlockRecord] in
            var m = BlockRecord(kind: .math)
            m.code = "\\int_0^\(i) x^2\\,dx = \\frac{\(i)^3}{3}"
            var d = BlockRecord(kind: .diagram)
            d.code = "graph TD\n  A\(i) --> B\(i)\n  B\(i) --> C\(i)"
            return [m, d]
        }
        write("diagramme-20", [text("Diagramme")] + diagrams)
        var big = Data(count: 50 << 20)
        big.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        let attachment = FolioArchive.Attachment(filename: "gross.bin", typeIdentifier: "public.data", data: big)
        var file = BlockRecord(kind: .file)
        file.attachmentID = attachment.id
        write("anhang-50mb", [text("Großer Anhang"), file], [attachment])
        return out
    }

    static func run() async {
        try? await Task.sleep(for: .seconds(2))
        let store = NoteStore.shared
        if ProcessInfo.processInfo.environment["FOLIO_SWITCH_BENCH"] == "synthetic" {
            let made = makeSyntheticNotes(in: store.rootURL)
            store.reload()
            let start = store.notes.first { !$0.url.lastPathComponent.hasPrefix("Bench-") }
            for (name, url) in made {
                guard let ref = store.notes.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { continue }
                var times: [Double] = []
                for _ in 0..<3 {
                    store.selectedNoteID = start?.id
                    settle()
                    store.closeDocument(ref.id)
                    times.append(measure { store.selectedNoteID = ref.id })
                    try? await Task.sleep(for: .milliseconds(300))
                }
                print(String(format: "SWITCH open %@ median %.1f ms max %.1f ms", name, times.sorted()[1], times.max() ?? 0))
            }
            print("SWITCH done")
            fflush(stdout)
            return
        }
        let notes = Array(store.notes.prefix(40))
        var noteTimes: [Double] = []
        for _ in 0..<2 {
            for n in notes {
                noteTimes.append(measure { store.selectedNoteID = n.id })
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        var folderTimes: [Double] = []
        let folders = Array(store.allFolderURLs.prefix(15))
        for _ in 0..<2 {
            for f in folders {
                folderTimes.append(measure { store.sidebarSelection = .folder(f) })
                try? await Task.sleep(for: .milliseconds(30))
            }
            folderTimes.append(measure { store.sidebarSelection = .all })
        }
        for (name, times) in [("note", noteTimes), ("folder", folderTimes)] where !times.isEmpty {
            let sorted = times.sorted()
            print(
                String(
                    format: "SWITCH %@ n=%d median %.1f ms p95 %.1f ms max %.1f ms", name, times.count, sorted[sorted.count / 2], sorted[Int(Double(sorted.count - 1) * 0.95)],
                    sorted.last ?? 0))
        }
        print("SWITCH done")
        fflush(stdout)
    }
}

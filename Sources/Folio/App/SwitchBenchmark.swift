import AppKit
import FolioCore

/// FOLIO_SWITCH_BENCH=1 with a throwaway FOLIO_LIBRARY: how long selecting notes and folders takes until the window has
/// laid itself out again (#388). Prints `SWITCH note|folder median … ms max … ms` and `SWITCH done`.
@MainActor
enum SwitchBenchmark {
    static func run() async {
        try? await Task.sleep(for: .seconds(2))
        let store = NoteStore.shared
        func settle() {
            for window in NSApp.windows where window.isVisible {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }
        func measure(_ change: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            change()
            settle()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
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

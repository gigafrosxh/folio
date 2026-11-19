import AppKit
import FolioCore

/// Incremental syntax colouring (#221), part of FOLIO_EDITOR_TEST: after typing, the colours must equal a full pass.
@MainActor
enum HighlightSelfTest {
    private static func check(_ ok: Bool, _ label: String) {
        print("EDIT", ok ? "ok" : "FAIL", label)
        fflush(stdout)
    }

    private static func colours(_ ts: NSTextStorage) -> [String] {
        var out: [String] = []
        ts.enumerateAttributes(in: NSRange(location: 0, length: ts.length)) { attrs, range, _ in
            out.append("\(range.location),\(range.length),\((attrs[.foregroundColor] as? NSColor)?.description ?? "-"),\((attrs[.font] as? NSFont)?.fontName ?? "-")")
        }
        return out
    }

    static func run(store: NoteStore) async {
        guard store.createNote() != nil, let doc = store.currentDocument else { return check(false, "Färbung: Notiz") }
        let code = BlockModel(kind: .code)
        code.storage.setAttributedString(NSAttributedString(string: (0..<200).map { i in i % 10 == 0 ? "s = \"zeile \(i)\"  # kommentar" : "wert_\(i) = berechne(daten, \(i))" }.joined(separator: "\n")))
        doc.insert(code, after: doc.blocks[0].id)
        doc.markDirty()
        try? await Task.sleep(for: .seconds(1.2))
        guard let tv = FormattingController.shared.codeView(for: code.id) else { return print("EDIT skip Färbung (keine Code-Ansicht)") }
        for (offset, text) in [(40, "x"), (0, "\"\"\"\n"), (300, "# neu "), (10, "def f(a):\n"), (0, "\"\"\"")] {
            tv.setSelectedRange(NSRange(location: min(offset, tv.string.utf16.count), length: 0))
            tv.insertText(text, replacementRange: tv.selectedRange())
        }
        guard let ts = tv.textStorage else { return }
        let incremental = colours(ts)
        code.revision += 1   // forces a full colouring pass in the view
        try? await Task.sleep(for: .seconds(0.6))
        check(colours(ts) == incremental, "Färbung nach dem Tippen wie bei vollem Durchlauf (\(incremental.count) Abschnitte)")
    }
}

#if os(iOS)
import Foundation
import UIKit
import FolioCore

/// Harness for the simulator (no screen access needed), like the Mac's `FOLIO_*_TEST` variables:
/// `FOLIO_PAD_SELFTEST=1` edits, saves, detects conflicts and trashes in `FOLIO_LIBRARY` and prints `PAD ok|FAIL …`;
/// `FOLIO_PAD_OPEN=<Titel>` opens that note at launch (for screenshots).
@MainActor
enum PadSelfTest {
    static func run(_ library: PadLibrary) {
        let env = ProcessInfo.processInfo.environment
        if let title = env["FOLIO_PAD_OPEN"], let entry = library.notes.first(where: { $0.meta.title == title }) {
            library.selectedNote = entry.url
        }
        guard env["FOLIO_PAD_SELFTEST"] != nil else { return }
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print("PAD", ok ? "ok" : "FAIL", what)
            if !ok { failures += 1 }
        }

        // New note: title from the first line, saved to disk.
        library.createNote(text: "Pad-Selbsttest\nzweite Zeile #ipad")
        guard let url = library.selectedNote, let doc = library.document else { check(false, "neue Notiz geöffnet"); return finish(failures) }
        let file = try? NoteFile.read(from: url)
        check(file?.meta.title == "Pad-Selbsttest", "neue Notiz: Titel aus erster Zeile")
        check(file?.meta.tags == ["ipad"], "neue Notiz: Tag erkannt")

        // Edit text and code, save: content and history version.
        let text = NSAttributedString(string: "Pad-Selbsttest geändert\nmit Text", attributes: [.font: UIFont.boldSystemFont(ofSize: 15)])
        doc.setText(text, of: doc.blocks[0].id)
        doc.appendCodeBlock()
        doc.setCode("print(1)", of: doc.blocks[1].id)
        library.saveNow()
        let saved = try? NoteFile.read(from: url)
        check(saved?.meta.title == "Pad-Selbsttest geändert", "Text bearbeitet und gesichert")
        check(saved?.body.blocks.last?.code == "print(1)", "Code-Block gesichert")
        check(!NoteHistory(library: library.root).versions(of: doc.file.meta.id).isEmpty, "Vorversion in .folio/history")
        let bold = saved.flatMap { PadDocument(file: $0).attributedText(of: $0.body.blocks[0]) }
        let font = bold?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        check(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true, "Formatierung (fett) bleibt erhalten")

        // Shown larger, saved at the Mac's size (#258).
        let mac = NSAttributedString(string: "x", attributes: [.font: UIFont.systemFont(ofSize: 13)])
        let shown = PadTextView.scaled(mac, by: PadTextView.displayScale)
        let back = PadTextView.scaled(shown, by: 1 / PadTextView.displayScale)
        let shownSize = (shown.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize ?? 0
        let backSize = (back.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize ?? 0
        check(shownSize > 13 && abs(backSize - 13) < 0.11, "Schrift größer angezeigt (\(shownSize) pt), mit 13 pt gesichert")

        // Blocks the iPad cannot edit stay byte for byte.
        if let other = library.notes.first(where: { ($0.meta.kinds ?? []).contains { $0 != "text" } && $0.url != url }),
           let before = try? NoteFile.read(from: other.url) {
            library.selectedNote = other.url
            if let d = library.document, let textBlock = d.blocks.first(where: { $0.kind == .text }) {
                d.setText(NSAttributedString(string: "Vom iPad geändert"), of: textBlock.id)
                library.saveNow()
                let after = try? NoteFile.read(from: other.url)
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let keep = { (f: NoteFile?) in f?.body.blocks.filter { $0.kind != .text }.map { try? encoder.encode($0) } ?? [] }
                check(keep(before) == keep(after), "andere Blöcke unverändert (\(other.meta.title))")
                check(Set(before.attachments.map(\.id)) == Set(after?.attachments.map(\.id) ?? []), "Anhänge unverändert")
            }
        }

        // Changed elsewhere: never overwritten, saved as a copy.
        library.selectedNote = url
        if let d = library.document {
            guard var foreign = try? NoteFile.read(from: url) else { check(false, "Konflikt: Datei lesbar"); return finish(failures) }
            foreign.body.blocks[0] = PadDocument.textRecord("Vom Mac geändert")
            Thread.sleep(forTimeInterval: 1.1)
            try? foreign.write(to: url)
            d.setText(NSAttributedString(string: "Vom iPad geändert"), of: d.blocks[0].id)
            library.saveNow()
            let onDisk = try? NoteFile.read(from: url)
            check(onDisk.map { PadDocument.plainText($0.body.blocks[0]) } == "Vom Mac geändert", "Konflikt: fremde Änderung bleibt")
            check(library.notes.contains { $0.url.lastPathComponent.contains("(iPad)") }, "Konflikt: eigene Fassung als Kopie")
        }

        // Trash instead of delete.
        library.selectedNote = url
        library.trashSelected()
        check(!FileManager.default.fileExists(atPath: url.path), "Papierkorb: Datei aus der Bibliothek")
        check(!LibraryTrash(library: library.root).items().isEmpty, "Papierkorb: Eintrag vorhanden")
        finish(failures)
    }

    private static func finish(_ failures: Int) {
        print("PAD done", failures == 0 ? "ok" : "\(failures) FAIL")
        fflush(stdout)
    }
}
#endif

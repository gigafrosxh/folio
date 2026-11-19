#if os(iOS)
import Foundation
import UIKit
import FolioCore

/// Harness for the simulator (no screen access needed), like the Mac's `FOLIO_*_TEST` variables:
/// `FOLIO_PAD_SELFTEST=1` edits, saves, detects conflicts and trashes in `FOLIO_LIBRARY` and prints `PAD ok|FAIL …`;
/// `FOLIO_PAD_OPEN=<Titel>` opens that note at launch (for screenshots).
@MainActor
final class PadSelfTest {
    private let library: PadLibrary
    private var failures = 0

    private init(_ library: PadLibrary) { self.library = library }

    static func run(_ library: PadLibrary) async {
        let env = ProcessInfo.processInfo.environment
        if let title = env["FOLIO_PAD_OPEN"], let entry = library.notes.first(where: { $0.meta.title == title }) {
            library.selectedNote = entry.url
        }
        // FOLIO_PAD_LIST=1: show the note list of the whole library (for screenshots on the iPhone).
        if env["FOLIO_PAD_LIST"] != nil, env["FOLIO_PAD_OPEN"] == nil { library.selectedFolder = library.root }
        guard env["FOLIO_PAD_SELFTEST"] != nil else { return }
        let test = PadSelfTest(library)
        // It edits and trashes notes: only ever in a test library (#260).
        guard env["FOLIO_LIBRARY"] != nil else { test.check(false, "FOLIO_PAD_SELFTEST braucht FOLIO_LIBRARY"); return test.finish() }
        await test.runAll()
    }

    private func check(_ ok: Bool, _ what: String) {
        print("PAD", ok ? "ok" : "FAIL", what)
        if !ok { failures += 1 }
    }

    private func finish() {
        print("PAD done", failures == 0 ? "ok" : "\(failures) FAIL")
        fflush(stdout)
    }

    private func runAll() async {
        guard let url = newNote() else { return finish() }
        editAndSave(url)
        await autosave(url)
        macChangeArrives(url)
        switchLibrary()
        displayScale()
        otherBlocksStay(except: url)
        conflict(url)
        conflictWhileSwitching(url)
        failedSave(url)
        trash(url)
        finish()
    }

    /// New note: title from the first line, saved to disk.
    private func newNote() -> URL? {
        library.createNote(text: "Pad-Selbsttest\nzweite Zeile #ipad")
        guard let url = library.selectedNote, library.document != nil else { check(false, "neue Notiz geöffnet"); return nil }
        let file = try? NoteFile.read(from: url)
        check(file?.meta.title == "Pad-Selbsttest", "neue Notiz: Titel aus erster Zeile")
        check(file?.meta.tags == ["ipad"], "neue Notiz: Tag erkannt")
        // Same title rules as the Mac (#265).
        if let doc = library.document {
            doc.setText(NSAttributedString(string: "— 19. Nov. 2026, 13:00 —\n• Punkt eins\nRest"), of: doc.blocks[0].id)
            library.saveNow()
            check((try? NoteFile.read(from: url))?.meta.title == "Punkt eins", "Titel ohne Listenzeichen und Datumszeile")
        }
        return url
    }

    /// Edit text and code, save: content, formatting and a history version.
    private func editAndSave(_ url: URL) {
        guard let doc = library.document else { return check(false, "Dokument offen") }
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
    }

    /// Autosave after a pause, compressed off the main thread (#264).
    private func autosave(_ url: URL) async {
        guard let doc = library.document else { return }
        doc.setCode("print(2)", of: doc.blocks[1].id)
        library.changed()
        try? await Task.sleep(for: .seconds(3))
        check(!doc.isDirty && (try? NoteFile.read(from: url))?.body.blocks.last?.code == "print(2)", "Automatisch gesichert (im Hintergrund komprimiert)")
    }

    /// A change made on the Mac (shared folder) shows up in the open note when it has no edits here (#213).
    private func macChangeArrives(_ url: URL) {
        library.selectedNote = url
        guard library.document?.isDirty == false else { return check(false, "Mac-Änderung: Dokument ungeändert offen") }
        changeOnDisk(url, to: "Auf dem Mac geschrieben")
        library.refreshFromDisk()
        let shown = library.document.map { PadDocument.plainText($0.blocks[0]) }
        check(shown == "Auf dem Mac geschrieben", "Änderung vom Mac erscheint in der offenen Notiz")
        check(library.notes.contains { $0.url == url && $0.meta.title == "Auf dem Mac geschrieben" }, "Änderung vom Mac erscheint in der Liste")
    }

    /// Another folder as library and back; nothing in either folder changes (#213).
    private func switchLibrary() {
        let original = library.root
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("folio-other-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        var note = NoteFile(meta: NoteMetadata(title: "Andere Bibliothek"), body: NoteBody(blocks: [PadDocument.textRecord("Andere Bibliothek")]))
        PadDocument.refreshMeta(&note)
        try? note.write(to: other.appendingPathComponent("Andere.folio"))
        let before = library.notes.count
        library.useLibrary(other)
        check(library.notes.map(\.meta.title) == ["Andere Bibliothek"], "Anderer Ordner als Bibliothek")
        library.useLibrary(original)
        check(library.notes.count == before && library.root == original, "Zurück zur Testbibliothek")
        UserDefaults.standard.removeObject(forKey: "libraryBookmark")
    }

    /// Shown larger, saved at the Mac's size (#258).
    private func displayScale() {
        let size = { (s: NSAttributedString) in (s.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize ?? 0 }
        let mac = NSAttributedString(string: "x", attributes: [.font: UIFont.systemFont(ofSize: 13)])
        let shown = PadTextView.scaled(mac, by: PadTextView.displayScale)
        let back = PadTextView.scaled(shown, by: 1 / PadTextView.displayScale)
        check(size(shown) > 13 && abs(size(back) - 13) < 0.11, "Schrift größer angezeigt (\(size(shown)) pt), mit 13 pt gesichert")
    }

    /// Blocks the iPad cannot edit stay byte for byte.
    private func otherBlocksStay(except url: URL) {
        guard let other = library.notes.first(where: { ($0.meta.kinds ?? []).contains { $0 != "text" } && $0.url != url }),
              let before = try? NoteFile.read(from: other.url) else { return }
        library.selectedNote = other.url
        guard let d = library.document, let textBlock = d.blocks.first(where: { $0.kind == .text }) else { return }
        d.setText(NSAttributedString(string: "Vom iPad geändert"), of: textBlock.id)
        library.saveNow()
        let after = try? NoteFile.read(from: other.url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let keep = { (f: NoteFile?) in f?.body.blocks.filter { $0.kind != .text }.map { try? encoder.encode($0) } ?? [] }
        check(keep(before) == keep(after), "andere Blöcke unverändert (\(other.meta.title))")
        check(Set(before.attachments.map(\.id)) == Set(after?.attachments.map(\.id) ?? []), "Anhänge unverändert")
    }

    private func changeOnDisk(_ url: URL, to text: String) {
        guard var foreign = try? NoteFile.read(from: url) else { return check(false, "Datei lesbar") }
        foreign.body.blocks[0] = PadDocument.textRecord(text)
        PadDocument.refreshMeta(&foreign)   // as the Mac would when it saves
        Thread.sleep(forTimeInterval: 1.1)
        try? foreign.write(to: url)
    }

    /// Changed elsewhere: never overwritten, saved as a copy with new ids.
    private func conflict(_ url: URL) {
        library.selectedNote = url
        guard let d = library.document else { return check(false, "Konflikt: Dokument offen") }
        changeOnDisk(url, to: "Vom Mac geändert")
        d.setText(NSAttributedString(string: "Vom iPad geändert"), of: d.blocks[0].id)
        library.saveNow()
        let onDisk = try? NoteFile.read(from: url)
        check(onDisk.map { PadDocument.plainText($0.body.blocks[0]) } == "Vom Mac geändert", "Konflikt: fremde Änderung bleibt")
        let copy = library.notes.first { $0.url.lastPathComponent.contains("(iPad)") }
        check(copy != nil, "Konflikt: eigene Fassung als Kopie")
        if let copy, let copyFile = try? NoteFile.read(from: copy.url), let onDisk {
            check(Set(copyFile.body.blocks.map(\.id)).isDisjoint(with: onDisk.body.blocks.map(\.id)), "Konfliktkopie mit neuen Block-IDs")
        }
    }

    /// Switching during a conflict keeps selection and editor together (#260).
    private func conflictWhileSwitching(_ url: URL) {
        library.selectedNote = url
        guard let d = library.document,
              let target = library.notes.first(where: { $0.url != url && !$0.url.lastPathComponent.contains("(iPad)") }) else { return }
        changeOnDisk(url, to: "Wieder vom Mac geändert")
        d.setText(NSAttributedString(string: "Wieder vom iPad"), of: d.blocks[0].id)
        library.selectedNote = target.url
        check(library.selectedNote == target.url && library.document?.url == target.url, "Konflikt beim Wechsel: Auswahl und Editor zeigen dieselbe Notiz")
    }

    /// A failed save keeps the edits open and the selection where it was (#260).
    private func failedSave(_ url: URL) {
        library.selectedNote = url
        let history = LibraryData.folder(library.root, "history")
        guard let d = library.document, let target = library.notes.first(where: { $0.url != url }) else { return }
        try? FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let folders = [history] + ((try? FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)) ?? [])
        setPermissions(0o500, folders)
        d.setText(NSAttributedString(string: "Ungesichert"), of: d.blocks[0].id)
        library.selectedNote = target.url
        check(library.selectedNote == url && library.document === d && d.isDirty, "Sichern fehlgeschlagen: Änderungen bleiben offen")
        let onDisk = try? NoteFile.read(from: url)
        check(onDisk.map { PadDocument.plainText($0.body.blocks[0]) } != "Ungesichert", "Sichern fehlgeschlagen: Datei ohne Vorversion nicht überschrieben")
        setPermissions(0o755, folders)
        library.message = nil
        library.saveNow()
        check(!d.isDirty, "Nach Freigabe gesichert")
    }

    private func setPermissions(_ mode: Int, _ folders: [URL]) {
        for f in folders { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: f.path) }
    }

    /// Trash instead of delete.
    private func trash(_ url: URL) {
        library.selectedNote = url
        library.trashSelected()
        check(!FileManager.default.fileExists(atPath: url.path), "Papierkorb: Datei aus der Bibliothek")
        check(!LibraryTrash(library: library.root).items().isEmpty, "Papierkorb: Eintrag vorhanden")
    }
}
#endif

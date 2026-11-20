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
            guard env["FOLIO_LIBRARY"] != nil else {
                test.check(false, "FOLIO_PAD_SELFTEST braucht FOLIO_LIBRARY")
                return test.finish()
            }
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
            savesInReverseOrder(url)
            await macChangeArrives(url)
            await switchLibrary()
            displayScale()
            otherBlocksStay(except: url)
            editDuringConflictCopy(url)
            conflict(url)
            conflictWhileSwitching(url)
            failedSave(url)
            unstorableText(url)
            damagedRTF()
            await overlappingAutosaves(url)
            sameSecondChange(url)
            deletedElsewhere()
            trash(url)
            finish()
        }

        /// New note: title from the first line, saved to disk.
        private func newNote() -> URL? {
            library.createNote(text: "Pad-Selbsttest\nzweite Zeile #ipad")
            guard let url = library.selectedNote, library.document != nil else {
                check(false, "neue Notiz geöffnet")
                return nil
            }
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
            // Up to 15 s: a busy CI simulator compresses slowly.
            for _ in 0..<30 where doc.isDirty { try? await Task.sleep(for: .milliseconds(500)) }
            check(!doc.isDirty && (try? NoteFile.read(from: url))?.body.blocks.last?.code == "print(2)", "Automatisch gesichert (im Hintergrund komprimiert)")
        }

        /// Two saves finishing in reverse order: the older snapshot never replaces the newer one on disk (#267).
        private func savesInReverseOrder(_ url: URL) {
            guard let doc = library.document, doc.url == url else { return check(false, "Reihenfolge: Dokument offen") }
            let history = NoteHistory(library: library.root)
            doc.setCode("print('alt')", of: doc.blocks[1].id)
            let older = doc.prepared(), olderRev = doc.revision
            doc.setCode("print('neu')", of: doc.blocks[1].id)
            let newer = doc.prepared(), newerRev = doc.revision
            let first = try? doc.write(newer, data: newer.encoded(), revision: newerRev, history: history)
            let second = try? doc.write(older, data: older.encoded(), revision: olderRev, history: history)
            let onDisk = (try? NoteFile.read(from: url))?.body.blocks.last?.code
            check(first.map { "\($0)" } == "saved" && second.map { "\($0)" } == "unchanged", "Älteres Sichern nach neuerem wird verworfen")
            check(onDisk == "print('neu')" && !doc.isDirty, "Neueste Fassung bleibt auf der Platte (#267)")
        }

        /// Editing while a conflict copy is written: the newer edit stays unsaved instead of being dropped (#268).
        private func editDuringConflictCopy(_ url: URL) {
            library.selectedNote = nil
            library.selectedNote = url
            guard let doc = library.document, doc.url == url else { return check(false, "Konfliktkopie: Dokument offen") }
            changeOnDisk(url, to: "Extern geändert (Revision)")
            doc.setCode("print('im Snapshot')", of: doc.blocks[1].id)
            let snapshot = doc.prepared(), rev = doc.revision
            doc.setCode("print('danach')", of: doc.blocks[1].id)
            let outcome = try? doc.write(snapshot, data: snapshot.encoded(), revision: rev, history: NoteHistory(library: library.root))
            guard case .savedAsCopy(let copy) = outcome else { return check(false, "Konfliktkopie angelegt") }
            check((try? NoteFile.read(from: copy))?.body.blocks.last?.code == "print('im Snapshot')", "Konfliktkopie enthält den Snapshot")
            check(doc.isDirty, "Neuere Eingabe bleibt ungesichert statt verloren (#268)")
            try? FileManager.default.removeItem(at: copy)
            library.reload()
        }

        /// Text that cannot be encoded as RTF keeps the block's previous content (#270).
        private func unstorableText(_ url: URL) {
            library.selectedNote = url
            guard let doc = library.document else { return check(false, "RTF-Fehler: Dokument offen") }
            let before = doc.blocks[0].rtf
            let encode = PadDocument.rtf
            PadDocument.rtf = { _ in nil }
            let accepted = doc.setText(NSAttributedString(string: "geht verloren"), of: doc.blocks[0].id)
            PadDocument.rtf = encode
            check(!accepted && doc.blocks[0].rtf == before, "RTF-Fehler: bisheriger Text bleibt erhalten (#270)")
        }

        /// Unreadable RTF is shown as damaged and its bytes are never replaced (#342).
        private func damagedRTF() {
            var block = BlockRecord(kind: .text)
            block.rtf = Data("{\\rtf1 kaputt".utf8) + Data([0xFF, 0x00, 0xFE])
            let doc = PadDocument(file: NoteFile(meta: NoteMetadata(title: "Kaputt"), body: NoteBody(blocks: [block])))
            check(PadDocument.isUnreadable(block) || doc.attributedText(of: block).length > 0, "Beschädigtes RTF erkannt")
            if PadDocument.isUnreadable(block) {
                check(!doc.setText(NSAttributedString(string: "Neu"), of: block.id) && doc.blocks[0].rtf == block.rtf, "Beschädigtes RTF bleibt unverändert (#342)")
            }
        }

        /// Several autosaves in a row never compress side by side and end with the newest text on disk (#336).
        private func overlappingAutosaves(_ url: URL) async {
            library.selectedNote = url
            guard let doc = library.document, doc.blocks.count > 1 else { return check(false, "Autosave-Folge: Dokument offen") }
            let history = NoteHistory(library: library.root)
            var tasks: [Task<Void, Never>] = []
            for i in 1...5 {
                doc.setCode("print(\(i))", of: doc.blocks[1].id)
                tasks.append(Task { _ = try? await doc.saveInBackground(history: history) })
            }
            for t in tasks { await t.value }
            check(!doc.isDirty && (try? NoteFile.read(from: url))?.body.blocks[1].code == "print(5)", "Schnelle Autosaves: neuester Stand gesichert (#336)")
        }

        /// A change elsewhere with the same modification date is still noticed (size and checksum differ) (#271).
        private func sameSecondChange(_ url: URL) {
            library.selectedNote = url
            library.saveNow()
            guard let doc = library.document, !doc.changedOnDisk,
                let date = PadDocument.modificationDate(url), var foreign = try? NoteFile.read(from: url)
            else { return check(false, "Gleiche Sekunde: Ausgangslage") }
            foreign.body.blocks[0] = PadDocument.textRecord("Gleichzeitig geändert, gleiche Sekunde")
            try? foreign.write(to: url)
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            check(doc.changedOnDisk, "Fremde Änderung mit gleichem Datum wird erkannt (#271)")
            library.reload()
            library.selectedNote = nil
            library.selectedNote = url
        }

        /// A note deleted elsewhere is not silently recreated when it is saved here (#269).
        private func deletedElsewhere() {
            library.createNote(text: "Wird anderswo gelöscht")
            guard let url = library.selectedNote, let doc = library.document else { return check(false, "Gelöscht: Notiz offen") }
            try? FileManager.default.removeItem(at: url)
            doc.setText(NSAttributedString(string: "Auf dem iPad weitergeschrieben"), of: doc.blocks[0].id)
            let result = library.saveNow()
            check(!FileManager.default.fileExists(atPath: url.path), "Gelöscht: Notiz nicht still neu angelegt (#269)")
            if case .copied(let copy) = result {
                check(FileManager.default.fileExists(atPath: copy.path) && library.message?.contains("gelöscht") == true, "Gelöscht: Änderungen in neuer Datei, Hinweis gezeigt")
                try? FileManager.default.removeItem(at: copy)
            } else {
                check(false, "Gelöscht: Änderungen in neuer Datei")
            }
            library.message = nil
            library.reload()
        }

        /// A change made on the Mac (shared folder) shows up in the open note when it has no edits here (#213).
        private func macChangeArrives(_ url: URL) async {
            library.selectedNote = url
            guard library.document?.isDirty == false else { return check(false, "Mac-Änderung: Dokument ungeändert offen") }
            changeOnDisk(url, to: "Auf dem Mac geschrieben")
            var refresh = library.refreshFromDisk()
            while refresh == nil {  // the 3-second refresh may be running
                try? await Task.sleep(for: .milliseconds(200))
                refresh = library.refreshFromDisk()
            }
            await refresh?.value
            let shown = library.document.map { PadDocument.plainText($0.blocks[0]) }
            check(shown == "Auf dem Mac geschrieben", "Änderung vom Mac erscheint in der offenen Notiz")
            check(library.notes.contains { $0.url == url && $0.meta.title == "Auf dem Mac geschrieben" }, "Änderung vom Mac erscheint in der Liste")
        }

        /// Another folder as library and back; nothing in either folder changes (#213).
        private func switchLibrary() async {
            let original = library.root
            let other = FileManager.default.temporaryDirectory.appendingPathComponent("folio-other-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            var note = NoteFile(meta: NoteMetadata(title: "Andere Bibliothek"), body: NoteBody(blocks: [PadDocument.textRecord("Andere Bibliothek")]))
            PadDocument.refreshMeta(&note)
            try? note.write(to: other.appendingPathComponent("Andere.folio"))
            let before = library.notes.count
            // The new library is read in the background (#302): wait for that scan.
            await library.useLibrary(other)?.value
            check(library.notes.map(\.meta.title) == ["Andere Bibliothek"], "Anderer Ordner als Bibliothek")
            await library.useLibrary(original)?.value
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
                let before = try? NoteFile.read(from: other.url)
            else { return }
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
            PadDocument.refreshMeta(&foreign)  // as the Mac would when it saves
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
                let target = library.notes.first(where: { $0.url != url && !$0.url.lastPathComponent.contains("(iPad)") })
            else { return }
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

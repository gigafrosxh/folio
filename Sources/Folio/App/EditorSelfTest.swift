import AppKit
import FolioCore

/// End-to-end check of undo, find & replace, tabs, split view, duplicates and focus mode (FOLIO_EDITOR_TEST).
@MainActor
enum EditorSelfTest {
    private static func check(_ ok: Bool, _ label: String) {
        print(ok ? "EDIT ok" : "EDIT FAIL", label)
        fflush(stdout)
    }

    private static func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    static func run() async {
        let store = NoteStore.shared
        let body = ThemeManager.shared.bodyAttributes
        await wait(1.5)
        guard let ref = store.createNote(), let doc = store.currentDocument else { check(false, "Notiz"); return }
        doc.blocks[0].storage.setAttributedString(NSAttributedString(string: "Erste Zeile mit Apfel\nZweite Zeile mit Apfel", attributes: body))
        doc.markDirty()
        await wait(1)
        let um = doc.undoManager ?? UndoManager()
        doc.undoManager = um
        check(doc.undoManager != nil, "Editor nutzt den Undo-Manager des Fensters")

        // Undo/redo (#3): insert in the middle of a text block, remove, move.
        let before = doc.blocks.count
        let code = BlockModel(kind: .code)
        code.storage.setAttributedString(NSAttributedString(string: "apfel = 1  # Apfel"))
        um.groupsByEvent = false
        um.beginUndoGrouping(); doc.insert(code, after: doc.blocks[0].id, splitAt: 21); um.endUndoGrouping()
        let afterInsert = doc.blocks.count
        let splitText = doc.blocks[0].storage.string
        um.undo()
        check(doc.blocks.count == before && doc.blocks[0].storage.string.contains("Zweite Zeile"), "Einfügen rückgängig (Text wieder zusammengefügt)")
        um.redo()
        check(doc.blocks.count == afterInsert && doc.blocks[0].storage.string == splitText && doc.blocks.contains { $0 === code }, "Einfügen wiederholt")
        um.beginUndoGrouping(); doc.remove(code.id); um.endUndoGrouping()
        check(!doc.blocks.contains { $0 === code }, "Block gelöscht")
        um.undo()
        check(doc.blocks.contains { $0 === code } && code.storage.string.contains("apfel"), "Löschen rückgängig, Inhalt erhalten")
        let img = BlockModel(kind: .drawing)
        um.beginUndoGrouping(); doc.insert(img, after: doc.blocks.last!.id); um.endUndoGrouping()
        let order = doc.blocks.map(\.id)
        um.beginUndoGrouping(); doc.move(img.id, by: -1); um.endUndoGrouping()
        check(doc.blocks.map(\.id) != order, "Block verschoben")
        um.undo()
        check(doc.blocks.map(\.id) == order, "Verschieben rückgängig")
        um.beginUndoGrouping(); doc.changeBlock(code, "Sprache ändern") { code.language = "ruby" }; um.endUndoGrouping()
        um.undo()
        check(code.language == "python", "Spracheinstellung rückgängig")
        um.groupsByEvent = true
        await wait(0.8)

        // Find & replace (#9)
        let find = FindModel()
        find.attach(doc)
        find.query = "apfel"
        check(find.matches.count == 4 && Set(find.matches.map(\.blockID)).count == 3, "Suche über Text- und Codeblöcke (\(find.matches.count) Treffer)")
        find.caseSensitive = true
        check(find.matches.count == 1, "Groß-/Kleinschreibung")
        find.caseSensitive = false
        find.next()
        check(find.current == 1, "Nächster Treffer")
        find.replacement = "Birne"
        find.replaceAll()
        let all = doc.blocks.map(\.storage.string).joined(separator: "\n")
        check(!all.lowercased().contains("apfel") && all.contains("Birne"), "Alle ersetzen")
        if um.canUndo { um.undo() }
        let restored = doc.blocks.map(\.storage.string).joined(separator: "\n")
        check(restored.contains("Apfel"), "Ersetzen rückgängig")
        find.detach()
        doc.saveNow()

        // Tabs and split view (#11, #12)
        guard let other = store.notes.first(where: { $0.id != ref.id }) else { check(false, "zweite Notiz"); return }
        store.openInNewTab(other.id)
        check(store.tabs == [ref.id, other.id] && store.selectedNoteID == other.id, "Zweiter Tab geöffnet, erster bleibt offen")
        check(store.documents[ref.id] != nil, "Erste Notiz bleibt im Tab geladen")
        store.selectedNoteID = ref.id
        check(store.tabs.count == 2, "Tabwechsel ersetzt keinen Tab")
        store.openInSplit(other.id)
        check(store.splitNoteID == other.id && store.selectedNoteID == ref.id, "Split View mit zwei Notizen")
        store.closeTab(other.id)
        check(store.tabs == [ref.id] && store.documents[other.id] != nil, "Tab geschlossen, Split hält die Notiz offen")
        store.splitNoteID = nil
        check(store.documents[other.id] == nil, "Nach dem Schließen wird die Notiz freigegeben")
        store.windowOpened(other.id)
        check(store.documents[other.id] != nil && store.currentDocument?.id == other.id, "Notiz im eigenen Fenster")
        store.windowClosed(other.id)
        check(store.documents[other.id] == nil, "Fenster geschlossen")

        // Duplicates (#16)
        if let withAttachment = store.notes.first(where: { (try? NoteFile.read(from: $0.url))?.attachments.isEmpty == false }),
           let original = try? NoteFile.read(from: withAttachment.url), let copyRef = store.duplicate(withAttachment.id),
           let copy = try? NoteFile.read(from: copyRef.url) {
            check(copy.meta.id != original.meta.id && copy.meta.title.hasSuffix("Kopie"), "Duplikat mit neuer ID")
            check(Set(copy.body.blocks.map(\.id)).isDisjoint(with: original.body.blocks.map(\.id)), "Neue Block-IDs")
            check(Set(copy.attachments.map(\.id)).isDisjoint(with: original.attachments.map(\.id))
                  && copy.attachments.map(\.data) == original.attachments.map(\.data), "Anhänge kopiert mit neuen IDs")
            check(copy.body.blocks.compactMap(\.attachmentID).allSatisfy { id in copy.attachments.contains { $0.id == id } }, "Verweise auf Anhänge stimmen")
        } else {
            check(false, "Notiz mit Anhang duplizieren")
        }

        // Focus mode (#10)
        UserDefaults.standard.set(false, forKey: "folio.focusMode")
        NotificationCenter.default.post(name: .folioToggleFocus, object: nil)
        await wait(0.3)
        check(UserDefaults.standard.bool(forKey: "folio.focusMode"), "Fokusmodus an")
        NotificationCenter.default.post(name: .folioToggleFocus, object: nil)
        await wait(0.3)
        check(!UserDefaults.standard.bool(forKey: "folio.focusMode"), "Fokusmodus aus")
        print("EDIT done"); fflush(stdout)
    }
}

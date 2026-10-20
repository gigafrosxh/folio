import AppKit
import FolioCore

/// End-to-end check of the data-safety features against a throwaway library (FOLIO_SAFETY_TEST).
@MainActor
enum SafetySelfTest {
    private static func check(_ ok: Bool, _ label: String) {
        print(ok ? "SAFETY ok" : "SAFETY FAIL", label)
        fflush(stdout)
    }

    private static func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    static func run() async {
        let store = NoteStore.shared
        await wait(1)
        guard let ref = store.createNote(), let doc = store.currentDocument else { check(false, "Notiz anlegen"); return }
        let body = ThemeManager.shared.bodyAttributes

        // Versions: the opened state plus one after editing (forced, since the 5-minute interval applies).
        doc.blocks[0].storage.setAttributedString(NSAttributedString(string: "Sicherheitstest\nErster Stand", attributes: body))
        doc.markDirty(); doc.saveNow()
        await wait(0.5)
        try? store.history.record(Data(contentsOf: doc.url), noteID: doc.id, force: true)
        doc.blocks[0].storage.setAttributedString(NSAttributedString(string: "Sicherheitstest\nZweiter Stand", attributes: body))
        doc.markDirty(); doc.saveNow()
        await wait(0.5)
        let versions = store.history.versions(of: doc.id)
        check(versions.count >= 2, "Versionen angelegt (\(versions.count))")
        if let first = versions.first(where: { (try? store.history.read($0)).map { NoteText.of($0).contains("Erster Stand") } ?? false }) {
            store.restoreVersion(first, of: doc)
            await wait(0.5)
            let restored = store.currentDocument.map { $0.blocks.map(\.storage.string).joined() } ?? ""
            check(restored.contains("Erster Stand"), "Version wiederhergestellt")
            check(store.history.versions(of: ref.id).contains { (try? store.history.read($0)).map { NoteText.of($0).contains("Zweiter Stand") } ?? false },
                  "vorheriger Stand blieb als Version erhalten")
        } else {
            check(false, "erste Version gefunden")
        }

        // Conflict: another app writes the file while there are unsaved edits.
        guard let current = store.currentDocument else { check(false, "Notiz offen"); return }
        if var other = try? NoteFile.read(from: current.url) {
            var b = BlockRecord(kind: .code)
            b.code = "von außen geändert"
            other.body.blocks.append(b)
            try? await Task.sleep(for: .milliseconds(100))
            try? other.write(to: current.url)
        }
        current.blocks[0].storage.append(NSAttributedString(string: "\nLokale Änderung", attributes: body))
        current.markDirty()
        current.saveNow()
        check(store.conflict != nil, "Konflikt erkannt statt überschrieben")
        let onDisk = (try? NoteFile.read(from: current.url)).map(NoteText.of) ?? ""
        check(onDisk.contains("von außen geändert") && !onDisk.contains("Lokale Änderung"), "externe Änderung blieb unangetastet")
        if let c = store.conflict {
            store.resolve(c, .keepBoth)
            await wait(0.5)
            let copy = store.notes.first { $0.meta.title.contains("Konflikt") }
            check(copy != nil, "Beide behalten: Konfliktkopie angelegt")
            if let copy, let file = try? NoteFile.read(from: copy.url) { check(NoteText.of(file).contains("Lokale Änderung"), "Konfliktkopie enthält die lokale Änderung") }
            let reopened = store.currentDocument.map { $0.blocks.map(\.storage.string).joined(separator: "\n") } ?? ""
            check(reopened.contains("von außen geändert"), "Notiz zeigt die externe Version")
        }

        // External change without local edits is simply loaded.
        if let doc2 = store.currentDocument, var other = try? NoteFile.read(from: doc2.url) {
            other.body.blocks.append({ var b = BlockRecord(kind: .code); b.code = "zweite externe Änderung"; return b }())
            try? other.write(to: doc2.url)
            store.checkExternalChange()
            await wait(0.3)
            check(store.currentDocument?.blocks.contains { $0.storage.string == "zweite externe Änderung" } == true, "externe Änderung ohne Konflikt übernommen")
        }

        // Trash
        let id = ref.id
        store.delete(id)
        check(!store.notes.contains { $0.id == id } && store.trashItems.contains { $0.noteIDs.contains(id) }, "Notiz im Papierkorb")
        if let item = store.trashItems.first(where: { $0.noteIDs.contains(id) }) {
            store.restore(item)
            check(store.notes.contains { $0.id == id } && store.selectedNoteID == id, "aus dem Papierkorb wiederhergestellt")
        }
        if let folder = store.createFolder(named: "Wegwerfordner") {
            store.createNote(in: folder)
            store.deleteFolder(folder)
            check(store.trashItems.contains { $0.isFolder && $0.noteCount == 1 }, "Ordner samt Notiz im Papierkorb")
        }

        // Backups
        BackupManager.shared.backupNow()
        for _ in 0..<60 where BackupManager.shared.isRunning { await wait(0.5) }
        check(BackupManager.shared.lastError == nil && BackupManager.shared.backups.count == 1,
              "Backup erstellt und geprüft: \(BackupManager.shared.status ?? BackupManager.shared.lastError ?? "-")")
        if let b = BackupManager.shared.backups.first {
            BackupManager.shared.restore(b)
            check(store.allFolderURLs.contains { $0.lastPathComponent.hasPrefix("Wiederhergestellt") }, "Backup als Ordner wiederhergestellt")
        }
        print("SAFETY done"); fflush(stdout)
    }
}

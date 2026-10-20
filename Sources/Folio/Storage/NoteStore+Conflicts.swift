import AppKit
import Combine
import FolioCore

extension NoteStore {
    // MARK: External changes

    /// Called every few seconds and when Folio becomes active.
    func checkExternalChange() {
        guard conflict == nil else { return }
        for doc in Array(documents.values) {
            guard let expected = doc.diskFingerprint, let current = FileFingerprint.of(doc.url) else { continue }   // moved/deleted: the next save recreates it
            guard current != expected else { continue }
            if doc.isDirty {
                raiseConflict(doc)
                return
            }
            // No unsaved edits here: follow the other app's version (our state stays in the history).
            reloadDocument(doc.id)
        }
    }

    func raiseConflict(_ doc: NoteDocument) {
        let data = try? Data(contentsOf: doc.url)
        doc.markDirtyWithoutSaving()
        conflict = NoteConflict(doc: doc, diskData: data, diskFile: data.flatMap { try? NoteFile.decode($0) })
    }

    enum ConflictChoice { case keepMine, takeTheirs, keepBoth }

    /// Resolves a conflict; whatever is not kept stays in the version history.
    func resolve(_ conflict: NoteConflict, _ choice: ConflictChoice) {
        let doc = conflict.doc
        self.conflict = nil
        let mine = doc.makeFile()
        switch choice {
        case .keepMine:
            if let theirs = conflict.diskData { try? history.record(theirs, noteID: doc.id, force: true) }
            doc.diskFingerprint = FileFingerprint.of(doc.url)
            doc.markDirty()
            doc.saveNow()
        case .takeTheirs:
            if let data = try? mine.encoded() { try? history.record(data, noteID: doc.id, force: true) }
            reloadDocument(doc.id)
        case .keepBoth:
            let stamp = Date().formatted(date: .numeric, time: .shortened).replacingOccurrences(of: ":", with: ".")
            saveAsNewNote(mine, in: doc.url.deletingLastPathComponent(), suffix: "(Konflikt \(stamp))")
            reloadDocument(doc.id)
        }
        if documents[doc.id] == nil, conflict.diskData == nil { reload() }
    }
}

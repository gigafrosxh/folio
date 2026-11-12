import AppKit
import Combine
import FolioCore

extension NoteStore {
    // MARK: External changes

    /// Called every few seconds and when Folio becomes active.
    func checkExternalChange() {
        checkOrganizationChange()
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
    /// Writes a version into the history; on failure the conflict stays open with a message (#186).
    private func keepInHistory(_ data: Data, _ conflict: NoteConflict) -> Bool {
        do {
            _ = try history.record(data, noteID: conflict.doc.id, force: true)
            return true
        } catch {
            reopenConflict(conflict, "Die Fassung, die ersetzt würde, konnte nicht im Versionsverlauf gesichert werden (\(error.localizedDescription)).")
            return false
        }
    }

    private func reopenConflict(_ conflict: NoteConflict, _ message: String) {
        self.conflict = conflict
        lastError = message + " Es wurde nichts überschrieben; der Konflikt bleibt offen."
    }

    func resolve(_ conflict: NoteConflict, _ choice: ConflictChoice) {
        let doc = conflict.doc
        self.conflict = nil
        let mine = doc.makeFile()
        switch choice {
        case .keepMine:
            // Keep what is on disk now, not only what was there when the conflict came up: the file may have
            // changed again since (#185). Without a copy in the history it is not overwritten (#186).
            let now = try? Data(contentsOf: doc.url)
            for data in [conflict.diskData, now].compactMap({ $0 }) where !keepInHistory(data, conflict) { return }
            doc.diskFingerprint = FileFingerprint.of(doc.url)
            doc.markDirty()
            doc.saveNow()
        case .takeTheirs:
            // The own version is only dropped once it is safe in the history (#186).
            guard let data = try? mine.encoded(), keepInHistory(data, conflict) else {
                if (try? mine.encoded()) == nil { reopenConflict(conflict, "Die eigene Fassung konnte nicht vorbereitet werden.") }
                return
            }
            reloadDocument(doc.id)
        case .keepBoth:
            // Own version into the history first, so it survives whatever happens next (#182).
            if let data = try? mine.encoded() { try? history.record(data, noteID: doc.id, force: true) }
            let stamp = Date().formatted(date: .numeric, time: .shortened).replacingOccurrences(of: ":", with: ".")
            guard saveAsNewNote(mine, in: doc.url.deletingLastPathComponent(), suffix: "(Konflikt \(stamp))") != nil else {
                // The copy could not be written: keep the own changes in the editor and the conflict open.
                self.conflict = conflict
                lastError = (lastError ?? "Die Kopie konnte nicht gesichert werden.")
                    + " Deine Änderungen sind weiter geöffnet und im Versionsverlauf gesichert; der Konflikt bleibt offen."
                return
            }
            reloadDocument(doc.id)
        }
        if documents[doc.id] == nil, conflict.diskData == nil { reload() }
    }
}

import AppKit
import Combine
import FolioCore

extension NoteStore {
    // MARK: Versions

    /// Replaces the open note with an earlier version (the current state becomes a version first).
    func restoreVersion(_ version: NoteVersion, of doc: NoteDocument) {
        do {
            var file = try history.read(version)
            doc.saveNow()
            if let current = try? Data(contentsOf: doc.url) { try? history.record(current, noteID: doc.id, force: true) }
            file.meta.id = doc.id
            file.meta.pinned = doc.meta.pinned
            file.meta.modified = Date()
            let data = try file.encoded()
            try data.write(to: doc.url, options: .atomic)
            reloadDocument(doc.id)
        } catch {
            lastError = "Die Version konnte nicht wiederhergestellt werden: \(error.localizedDescription)"
        }
    }

    /// Saves an earlier version (or any note file) as a separate new note next to `folder`.
    @discardableResult
    func saveAsNewNote(_ file: NoteFile, in folder: URL, suffix: String) -> NoteRef? {
        var f = file
        f.meta.id = UUID()
        f.meta.title = (f.meta.title.isEmpty ? "Notiz" : f.meta.title) + " " + suffix
        f.meta.modified = Date()
        let url = uniqueURL(in: folder, base: Self.sanitize(f.meta.title))
        do { try f.write(to: url) } catch {
            lastError = "Die Kopie konnte nicht gesichert werden: \(error.localizedDescription)"
            return nil
        }
        let ref = NoteRef(meta: f.meta, url: url)
        notes.append(ref)
        return ref
    }

    /// Reopens a note from disk (after a restore, a tag edit or when taking the external version);
    /// every tab, split view and window showing it gets the new document.
    func reloadDocument(_ id: UUID) {
        guard let old = documents[id] else { return }
        let url = old.url
        KernelManager.shared.shutdown(note: id)
        // Undo steps of the replaced document would change an invisible copy; drop them.
        let undoManager = old.undoManager
        undoManager?.removeAllActions(withTarget: old)
        documents[id] = nil
        open(url, id: id)
        documents[id]?.undoManager = undoManager
        if let doc = documents[id], let i = notes.firstIndex(where: { $0.id == id }) {
            notes[i] = NoteRef(meta: doc.meta, url: url)
        }
    }
}

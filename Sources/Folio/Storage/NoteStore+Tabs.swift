import AppKit
import Combine
import FolioCore

extension NoteStore {
    // MARK: Tabs, split view, windows

    func openInNewTab(_ id: UUID) {
        if tabs.contains(id) {
            selectedNoteID = id
            return
        }
        nextSelectionInNewTab = true
        if selectedNoteID == id {
            tabs.append(id)
            nextSelectionInNewTab = false
        } else {
            selectedNoteID = id
        }
    }

    func createNoteInNewTab() {
        nextSelectionInNewTab = true
        if createNote() == nil { nextSelectionInNewTab = false }
    }

    func closeTab(_ id: UUID) {
        guard let i = tabs.firstIndex(of: id) else { return }
        documents[id]?.saveNow()
        // Saving failed: the tab stays, or its unsaved text would be gone (#183).
        if documents[id]?.isDirty == true {
            let reason = conflict?.doc.id == id ? "Die Notiz hat einen offenen Konflikt; entscheide zuerst, welche Fassung gilt." : (lastError ?? "Speichern fehlgeschlagen.")
            lastError = reason + " Der Tab bleibt offen, damit nichts verloren geht."
            return
        }
        tabs.remove(at: i)
        if selectedNoteID == id {
            let next = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)]
            nextSelectionInNewTab = false
            // Avoid replacing a tab: the closed one is gone already.
            let saved = tabs
            selectedNoteID = next
            tabs = saved
        }
        releaseUnused()
    }

    func selectTab(offset: Int) {
        guard tabs.count > 1, let id = selectedNoteID, let i = tabs.firstIndex(of: id) else { return }
        selectedNoteID = tabs[(i + offset + tabs.count) % tabs.count]
    }

    func openInSplit(_ id: UUID) {
        if id == selectedNoteID, tabs.count > 1, let other = tabs.first(where: { $0 != id }) { selectedNoteID = other }
        splitNoteID = id
        focusedNoteID = id
    }

    func windowOpened(_ id: UUID) {
        if !windowNoteIDs.contains(id) { windowNoteIDs.append(id) }
        ensureLoaded(id)
        focusedNoteID = id
    }

    func windowClosed(_ id: UUID) {
        if let i = windowNoteIDs.firstIndex(of: id) { windowNoteIDs.remove(at: i) }
        if focusedNoteID == id { focusedNoteID = selectedNoteID }
        releaseUnused()
    }

    /// Loads a note into the editor. A file that cannot be decoded is diagnosed instead of opened.
    func open(_ url: URL, id: UUID) {
        guard let data = try? Data(contentsOf: url) else {
            failures[id] = DamagedNote(url: url, report: FolioDiagnostics.diagnose(at: url))
            return
        }
        do {
            adopt(try NoteFile.decode(data), data: data, url: url, id: id)
        } catch {
            failures[id] = DamagedNote(url: url, report: FolioDiagnostics.diagnose(data))
        }
    }

    /// Makes a decoded note the open document (read here or in the background, #388).
    func adopt(_ file: NoteFile, data: Data, url: URL, id: UUID) {
        let doc = NoteDocument(file: file, url: url)
        doc.store = self
        doc.diskFingerprint = FileFingerprint(data: data)
        documents[id] = doc
        AttachmentSync.syncExternalEdits(in: doc)
        doc.indexPDFs()
        // The state on disk before any edit is always in the history.
        recordVersion(data, noteID: file.meta.id, force: true)
    }

    /// Writes a version in the background (versions never slow down typing).
    func recordVersion(_ data: Data, noteID: UUID, force: Bool = false) {
        let history = self.history
        Task.detached(priority: .utility) { _ = try? history.record(data, noteID: noteID, force: force) }
    }

    /// The edits of a note whose file vanished, as a new note with new ids; the old one is closed (#365).
    func rescueDeleted(_ doc: NoteDocument) {
        let file = NoteIdentity.renewed(doc.makeFile())
        let parent = doc.url.deletingLastPathComponent()
        let folder = FileManager.default.fileExists(atPath: parent.path) ? parent : rootURL
        guard let ref = saveAsNewNote(file, in: folder, suffix: "(gerettet)") else {
            doc.markDirtyWithoutSaving()
            return
        }
        let oldID = doc.id
        closeDocument(oldID)
        notes.removeAll { $0.id == oldID }
        tabs.removeAll { $0 == oldID }
        if selectedNoteID == oldID || selectedNoteID == nil { selectedNoteID = ref.id }
        lastError = "„\(doc.meta.title)“ wurde außerhalb von Folio gelöscht oder verschoben. Deine Änderungen liegen jetzt in „\(ref.meta.title)“."
    }

    func save(_ doc: NoteDocument) {
        // Never overwrite a change made outside Folio since the note was loaded or last saved.
        // Still unresolved: the own changes are not on disk, so the note stays unsaved for every guard (#206).
        if conflict?.doc === doc {
            doc.markDirtyWithoutSaving()
            return
        }
        // Deleted or moved elsewhere since it was opened: never recreate it silently at the old place (a moved note
        // would exist twice with the same id); the edits become a new note next to it (#365, like #269 on the iPad).
        if doc.diskFingerprint != nil, !FileManager.default.fileExists(atPath: doc.url.path), !isTemplate(doc.url) {
            rescueDeleted(doc)
            return
        }
        if let expected = doc.diskFingerprint, let current = FileFingerprint.of(doc.url), current != expected {
            raiseConflict(doc)
            return
        }
        let file = doc.makeFile()
        let data: Data
        do {
            data = try file.encoded()
            try data.write(to: doc.url, options: .atomic)
        } catch {
            doc.markDirtyWithoutSaving()
            lastError = "Speichern fehlgeschlagen: \(error.localizedDescription)"
            return
        }
        doc.diskFingerprint = FileFingerprint(data: data)
        recordVersion(data, noteID: doc.id)
        renameIfNeeded(doc)
        if isTemplate(doc.url) {
            if let i = templates.firstIndex(where: { $0.id == doc.id }) { templates[i] = NoteRef(meta: file.meta, url: doc.url) }
        } else if let i = notes.firstIndex(where: { $0.id == doc.id }) {
            notes[i] = NoteRef(meta: file.meta, url: doc.url)
        } else {
            notes.append(NoteRef(meta: file.meta, url: doc.url))
        }
    }

    /// Opens a note by id (note links, backlinks, quick open), leaving filters that would hide it.
    func open(noteID: UUID) {
        guard notes.contains(where: { $0.id == noteID }) else {
            lastError = "Die verlinkte Notiz gibt es nicht mehr (vielleicht im Papierkorb)."
            return
        }
        if !filteredNotes.contains(where: { $0.id == noteID }) {
            searchText = ""
            searchFilter = SearchFilter()
            sidebarSelection = .all
        }
        selectedNoteID = noteID
    }
}

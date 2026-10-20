import AppKit
import Combine
import FolioCore

extension NoteStore {
    // MARK: Tabs, split view, windows

    func openInNewTab(_ id: UUID) {
        if tabs.contains(id) { selectedNoteID = id; return }
        nextSelectionInNewTab = true
        if selectedNoteID == id { tabs.append(id); nextSelectionInNewTab = false } else { selectedNoteID = id }
    }

    func createNoteInNewTab() {
        nextSelectionInNewTab = true
        if createNote() == nil { nextSelectionInNewTab = false }
    }

    func closeTab(_ id: UUID) {
        guard let i = tabs.firstIndex(of: id) else { return }
        documents[id]?.saveNow()
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
            let file = try NoteFile.decode(data)
            let doc = NoteDocument(file: file, url: url)
            doc.store = self
            doc.diskFingerprint = FileFingerprint(data: data)
            documents[id] = doc
            AttachmentSync.syncExternalEdits(in: doc)
            // The state on disk before any edit is always in the history.
            recordVersion(data, noteID: file.meta.id, force: true)
        } catch {
            failures[id] = DamagedNote(url: url, report: FolioDiagnostics.diagnose(data))
        }
    }

    /// Writes a version in the background (versions never slow down typing).
    func recordVersion(_ data: Data, noteID: UUID, force: Bool = false) {
        let history = self.history
        Task.detached(priority: .utility) { _ = try? history.record(data, noteID: noteID, force: force) }
    }

    func save(_ doc: NoteDocument) {
        // Never overwrite a change made outside Folio since the note was loaded or last saved.
        if conflict?.doc === doc { return }
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

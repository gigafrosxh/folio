import AppKit
import Combine
import FolioCore

extension NoteStore {
    // MARK: Templates


    func isTemplate(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(templatesFolder.standardizedFileURL.path + "/")
    }

    static func scanTemplates(_ dir: URL) -> [NoteRef] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == FolioArchive.fileExtension }
            .compactMap { url in (try? NoteFile.readMetadata(at: url)).map { NoteRef(meta: $0, url: url) } }
    }

    /// Creates the starter templates (Meeting, Lernnotiz, Projekt) the first time templates are used.
    func ensureStarterTemplates() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: templatesFolder.path) else { return }
        try? fm.createDirectory(at: templatesFolder, withIntermediateDirectories: true)
        for t in StarterTemplates.all { _ = writeTemplate(t) }
        templates = Self.scanTemplates(templatesFolder)
    }

    func writeTemplate(_ file: NoteFile) -> URL? {
        try? FileManager.default.createDirectory(at: templatesFolder, withIntermediateDirectories: true)
        let url = uniqueURL(in: templatesFolder, base: Self.sanitize(file.meta.title))
        do { try file.write(to: url) } catch {
            lastError = "Die Vorlage konnte nicht gesichert werden: \(error.localizedDescription)"
            return nil
        }
        return url
    }

    /// A new note from a template: placeholders like {{datum}}, {{titel}} and {{cursor}} filled in (#118),
    /// new id, in the target folder. The cursor goes where {{cursor}} was.
    @discardableResult
    func createNote(from template: NoteRef, in folder: URL? = nil, title: String? = nil, date: Date = Date()) -> NoteRef? {
        guard var file = try? NoteFile.read(from: template.url) else {
            lastError = "Die Vorlage „\(template.meta.title)“ ist nicht lesbar."
            return nil
        }
        let context = TemplateVariables.Context(date: date, title: title ?? TemplateText.fill(template.meta.title, now: date))
        let cursor = Self.fillTemplate(&file, title: title, context: context)
        guard let url = writeNewNote(file, in: folder) else { return nil }
        let ref = NoteRef(meta: file.meta, url: url)
        notes.append(ref)
        // Like a plain new note (#162): places that cannot show it switch to all notes, the graph too (#210).
        if sidebarSelection == .templates || Self.selectionAfterCreatingNote(sidebarSelection) != nil { sidebarSelection = .all }
        selectedNoteID = ref.id
        if let cursor { FormattingController.shared.focus(blockID: cursor.block, at: cursor.offset) }
        return ref
    }

    /// Fills in the placeholders and gives the note fresh ids. Returns where {{cursor}} was. Touches no file.
    static func fillTemplate(_ file: inout NoteFile, title: String?, context: TemplateVariables.Context) -> (block: UUID, offset: Int)? {
        var cursor: (block: UUID, offset: Int)?
        for i in file.body.blocks.indices {
            file.body.blocks[i].id = UUID()
            if let found = fillBlock(&file.body.blocks[i], context: context), cursor == nil { cursor = (file.body.blocks[i].id, found) }
        }
        file.meta.id = UUID()
        file.meta.title = title ?? TemplateVariables.apply(file.meta.title, context: context).text
        file.meta.created = Date()
        file.meta.modified = Date()
        file.meta.pinned = false
        return cursor
    }

    private static func fillBlock(_ block: inout BlockRecord, context: TemplateVariables.Context) -> Int? {
        if block.kind == .text, let rtf = block.rtf {
            let text = RichTextCodec.attributedString(from: rtf)
            let cursor = TemplateVariables.apply(to: text, context: context)
            block.rtf = RichTextCodec.rtfData(from: text)
            return cursor
        }
        if let code = block.code { block.code = TemplateVariables.apply(code, context: context).text }
        return nil
    }

    private func writeNewNote(_ file: NoteFile, in folder: URL?) -> URL? {
        let dir = folder ?? (sidebarSelection == .templates ? rootURL.appendingPathComponent(Self.defaultFolderName) : targetFolder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = uniqueURL(in: dir, base: Self.sanitize(file.meta.title.isEmpty ? "Neue Notiz" : file.meta.title))
        do {
            try file.write(to: url)
            return url
        } catch {
            lastError = "Notiz konnte nicht angelegt werden: \(error.localizedDescription)"
            return nil
        }
    }

    /// Saves a copy of a note as a new template.
    func saveAsTemplate(_ doc: NoteDocument) {
        doc.saveNow()
        var file = doc.makeFilePreview()
        file.meta.id = UUID()
        file.meta.pinned = false
        if file.meta.title.isEmpty { file.meta.title = "Vorlage" }
        guard writeTemplate(file) != nil else { return }
        templates = Self.scanTemplates(templatesFolder)
        sidebarSelection = .templates
        selectedNoteID = file.meta.id
    }

    /// An empty template, opened for editing.
    func createTemplate() {
        var b = BlockRecord(kind: .text)
        b.rtf = RichTextCodec.rtfData(from: NSAttributedString(string: "Neue Vorlage\n{{datum}}\n", attributes: ThemeManager.shared.bodyAttributes))
        let file = NoteFile(meta: NoteMetadata(title: "Neue Vorlage"), body: NoteBody(blocks: [b]))
        guard writeTemplate(file) != nil else { return }
        templates = Self.scanTemplates(templatesFolder)
        sidebarSelection = .templates
        selectedNoteID = file.meta.id
    }

    func deleteTemplate(_ ref: NoteRef) {
        let wasSelected = selectedNoteID == ref.id
        closeDocument(ref.id)
        if wasSelected { selectedNoteID = nil }
        try? FileManager.default.trashItem(at: ref.url, resultingItemURL: nil)
        templates = Self.scanTemplates(templatesFolder)
    }

    /// Keeps file names readable: the file is named after the note's title.
    func renameIfNeeded(_ doc: NoteDocument) {
        let base = Self.sanitize(doc.meta.title.isEmpty ? "Neue Notiz" : doc.meta.title)
        let current = doc.url.deletingPathExtension().lastPathComponent
        if current == base || current.hasPrefix(base + " ") && Int(current.dropFirst(base.count + 1)) != nil { return }
        let target = uniqueURL(in: doc.url.deletingLastPathComponent(), base: base)
        do {
            try FileManager.default.moveItem(at: doc.url, to: target)
            doc.url = target
        } catch {
            // Keep the old name; the note itself is saved.
        }
    }

    func togglePin(_ id: UUID) {
        if let doc = documents[id] {
            doc.setPinned(!doc.meta.pinned)
            doc.saveNow()
            return
        }
        guard let ref = notes.first(where: { $0.id == id }), var file = try? NoteFile.read(from: ref.url) else { return }
        file.meta.pinned.toggle()
        try? file.write(to: ref.url)
        if let i = notes.firstIndex(where: { $0.id == id }) { notes[i].meta = file.meta }
    }

    /// Saves an open note before it goes to the trash. False (with a message) when its newest changes could not be
    /// written: the trash would only get the older state (#191).
    private func savedBeforeDeleting(_ id: UUID) -> Bool {
        guard let doc = documents[id] else { return true }
        doc.saveNow()
        guard doc.isDirty else { return true }
        lastError = "„\(doc.meta.title.isEmpty ? "Neue Notiz" : doc.meta.title)“ wurde nicht gelöscht: Die letzten Änderungen konnten nicht gesichert werden."
        return false
    }

    /// Moves a note into Folio's trash (restorable; its versions are kept).
    func delete(_ id: UUID) {
        if let t = templates.first(where: { $0.id == id }) { deleteTemplate(t); return }
        // Saved before the path is read: a new title renames the file (#196).
        guard notes.contains(where: { $0.id == id }), savedBeforeDeleting(id), let ref = notes.first(where: { $0.id == id }) else { return }
        let wasSelected = selectedNoteID == id
        let tabsBefore = tabs
        if let data = try? Data(contentsOf: ref.url) { try? history.record(data, noteID: id, force: true) }
        do {
            try trash.moveToTrash(ref.url, title: ref.meta.title.isEmpty ? nil : ref.meta.title)
        } catch {
            lastError = "Löschen fehlgeschlagen: \(error.localizedDescription)"
            return
        }
        trashItems = trash.items()
        let list = filteredNotes
        let idx = list.firstIndex(where: { $0.id == id })
        notes.removeAll { $0.id == id }
        closeDocument(id)
        if wasSelected { selectAfterDeleting(id, tabsBefore: tabsBefore, listIndex: idx) }
    }

    /// The next tab, or the note that took the deleted one's place in the list.
    private func selectAfterDeleting(_ id: UUID, tabsBefore: [UUID], listIndex idx: Int?) {
        if tabsBefore.count > 1 {
            let i = tabsBefore.firstIndex(of: id) ?? 0
            let next = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)]
            let saved = tabs
            selectedNoteID = next
            tabs = saved
        } else {
            let remaining = filteredNotes
            selectedNoteID = idx.flatMap { remaining.indices.contains($0) ? remaining[$0].id : remaining.last?.id }
        }
    }

    /// Copies a note with all blocks and attachments under new ids (#16), next to the original.
    @discardableResult
    func duplicate(_ id: UUID) -> NoteRef? {
        // Saving first: a new title renames the file, so its path is only known afterwards (#196).
        documents[id]?.saveNow()
        guard let ref = notes.first(where: { $0.id == id }) ?? templates.first(where: { $0.id == id }) else { return nil }
        guard let original = try? NoteFile.read(from: ref.url) else {
            lastError = "„\(ref.meta.title)“ konnte nicht gelesen werden."
            return nil
        }
        let copy = Self.duplicated(original)
        let url = uniqueURL(in: ref.folderURL, base: Self.sanitize(copy.meta.title))
        do { try copy.write(to: url) } catch {
            lastError = "Duplizieren fehlgeschlagen: \(error.localizedDescription)"
            return nil
        }
        let newRef = NoteRef(meta: copy.meta, url: url)
        if isTemplate(url) {
            templates = Self.scanTemplates(templatesFolder)
        } else {
            notes.append(newRef)
        }
        selectedNoteID = newRef.id
        return newRef
    }

    /// A copy with a new note id, new block ids and new attachment ids (references updated).
    static func duplicated(_ file: NoteFile, now: Date = Date()) -> NoteFile {
        var copy = file
        copy.meta.id = UUID()
        copy.meta.title = (file.meta.title.isEmpty ? "Notiz" : file.meta.title) + " Kopie"
        copy.meta.created = now
        copy.meta.modified = now
        copy.meta.pinned = false
        var map: [UUID: UUID] = [:]
        copy.attachments = file.attachments.map { a in
            let newID = UUID()
            map[a.id] = newID
            return FolioArchive.Attachment(id: newID, filename: a.header.filename, typeIdentifier: a.header.typeIdentifier,
                                           isPackage: a.header.isPackage, data: a.data)
        }
        for i in copy.body.blocks.indices {
            copy.body.blocks[i].id = UUID()
            if let old = copy.body.blocks[i].attachmentID { copy.body.blocks[i].attachmentID = map[old] }
        }
        return copy
    }

    func move(_ id: UUID, to folder: URL) {
        // Saved before the path is read: a new title renames the file (#196).
        documents[id]?.saveNow()
        guard let ref = notes.first(where: { $0.id == id }),
              ref.folderURL.standardizedFileURL != folder.standardizedFileURL else { return }
        let target = uniqueURL(in: folder, base: ref.url.deletingPathExtension().lastPathComponent)
        do {
            try FileManager.default.moveItem(at: ref.url, to: target)
        } catch {
            lastError = "Verschieben fehlgeschlagen: \(error.localizedDescription)"
            return
        }
        if let i = notes.firstIndex(where: { $0.id == id }) { notes[i].url = target }
        documents[id]?.url = target
    }
}

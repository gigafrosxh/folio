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

    /// A new note from a template: placeholders like {{datum}} filled in, new id, in the target folder.
    @discardableResult
    func createNote(from template: NoteRef, in folder: URL? = nil) -> NoteRef? {
        guard var file = try? NoteFile.read(from: template.url) else {
            lastError = "Die Vorlage „\(template.meta.title)“ ist nicht lesbar."
            return nil
        }
        let values = TemplateText.values()
        for i in file.body.blocks.indices {
            let b = file.body.blocks[i]
            if b.kind == .text, let rtf = b.rtf {
                let s = RichTextCodec.attributedString(from: rtf)
                for (key, value) in values {
                    s.mutableString.replaceOccurrences(of: "{{\(key)}}", with: value, options: .caseInsensitive,
                                                       range: NSRange(location: 0, length: s.length))
                }
                file.body.blocks[i].rtf = RichTextCodec.rtfData(from: s)
            } else if let code = b.code {
                file.body.blocks[i].code = TemplateText.fill(code)
            }
            file.body.blocks[i].id = UUID()
        }
        file.meta.id = UUID()
        file.meta.title = TemplateText.fill(file.meta.title)
        file.meta.created = Date()
        file.meta.modified = Date()
        file.meta.pinned = false
        let dir = folder ?? (sidebarSelection == .templates ? rootURL.appendingPathComponent(Self.defaultFolderName) : targetFolder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = uniqueURL(in: dir, base: Self.sanitize(file.meta.title.isEmpty ? "Neue Notiz" : file.meta.title))
        do { try file.write(to: url) } catch {
            lastError = "Notiz konnte nicht angelegt werden: \(error.localizedDescription)"
            return nil
        }
        let ref = NoteRef(meta: file.meta, url: url)
        notes.append(ref)
        if sidebarSelection == .templates || sidebarSelection == .trash || sidebarSelection == .damaged || sidebarSelection == .pinned {
            sidebarSelection = .all
        }
        selectedNoteID = ref.id
        return ref
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

    /// Moves a note into Folio's trash (restorable; its versions are kept).
    func delete(_ id: UUID) {
        if let t = templates.first(where: { $0.id == id }) { deleteTemplate(t); return }
        guard let ref = notes.first(where: { $0.id == id }) else { return }
        documents[id]?.saveNow()
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
        if wasSelected {
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
    }

    /// Copies a note with all blocks and attachments under new ids (#16), next to the original.
    @discardableResult
    func duplicate(_ id: UUID) -> NoteRef? {
        guard let ref = notes.first(where: { $0.id == id }) ?? templates.first(where: { $0.id == id }) else { return nil }
        documents[id]?.saveNow()
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
        guard let ref = notes.first(where: { $0.id == id }),
              ref.folderURL.standardizedFileURL != folder.standardizedFileURL else { return }
        documents[id]?.saveNow()
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

import AppKit
import Combine
import FolioCore

struct NoteRef: Identifiable, Hashable {
    var meta: NoteMetadata
    var url: URL
    var id: UUID { meta.id }
    var folderURL: URL { url.deletingLastPathComponent() }
}

struct FolderNode: Identifiable, Hashable {
    var url: URL
    var name: String
    var children: [FolderNode]?
    var id: URL { url }
}

enum SidebarItem: Hashable {
    case all
    case pinned
    case folder(URL)
    case tag(String)
}

/// A note that the Apple Notes importer produced, ready to be written into the library.
struct ImportedNote {
    /// Folder names below the library root, e.g. ["Apple Notizen", "iCloud", "Rezepte"].
    var folderPath: [String]
    var file: NoteFile
}

/// The note library: a folder tree on disk where every note is one `.folio` file.
/// Folders are real directories, so the library can be browsed, synced and backed up like any files.
@MainActor
final class NoteStore: ObservableObject {
    static let shared = NoteStore()

    @Published private(set) var rootURL: URL
    @Published private(set) var folders: [FolderNode] = []
    @Published private(set) var notes: [NoteRef] = []
    @Published var sidebarSelection: SidebarItem? = .all {
        didSet { if oldValue != sidebarSelection, let id = selectedNoteID, !filteredNotes.contains(where: { $0.id == id }) { selectedNoteID = filteredNotes.first?.id } }
    }
    @Published var selectedNoteID: UUID? {
        didSet { if oldValue != selectedNoteID { openSelected() } }
    }
    @Published private(set) var currentDocument: NoteDocument?
    @Published var searchText = ""
    @Published var lastError: String?

    static let defaultFolderName = "Notizen"

    private init() {
        // FOLIO_LIBRARY overrides the library folder (used for debugging without touching real notes).
        let path = ProcessInfo.processInfo.environment["FOLIO_LIBRARY"] ?? ThemeManager.shared.settings.libraryPath
        rootURL = URL(fileURLWithPath: path, isDirectory: true)
        prepareRoot()
        reload()
    }

    // MARK: Library

    func setLibrary(_ url: URL) {
        currentDocument?.saveNow()
        currentDocument = nil
        selectedNoteID = nil
        rootURL = url
        ThemeManager.shared.settings.libraryPath = url.path
        prepareRoot()
        reload()
    }

    private func prepareRoot() {
        let fm = FileManager.default
        try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let defaultFolder = rootURL.appendingPathComponent(Self.defaultFolderName, isDirectory: true)
        if (try? fm.contentsOfDirectory(atPath: rootURL.path))?.filter({ !$0.hasPrefix(".") }).isEmpty ?? true {
            try? fm.createDirectory(at: defaultFolder, withIntermediateDirectories: true)
        }
    }

    func reload() {
        let fm = FileManager.default
        var found: [NoteRef] = []
        func scan(_ dir: URL) -> [FolderNode] {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
            var nodes: [FolderNode] = []
            for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                if item.pathExtension == FolioArchive.fileExtension {
                    if let meta = try? NoteFile.readMetadata(at: item) { found.append(NoteRef(meta: meta, url: item)) }
                } else if values?.isDirectory == true && values?.isPackage != true {
                    let children = scan(item)
                    nodes.append(FolderNode(url: item, name: item.lastPathComponent, children: children.isEmpty ? nil : children))
                }
            }
            return nodes
        }
        folders = scan(rootURL)
        notes = found
        if let id = selectedNoteID, !notes.contains(where: { $0.id == id }) { selectedNoteID = nil }
    }

    // MARK: Queries

    var filteredNotes: [NoteRef] {
        var list = notes
        switch sidebarSelection ?? .all {
        case .all: break
        case .pinned: list = list.filter(\.meta.pinned)
        case .folder(let url): list = list.filter { $0.folderURL.standardizedFileURL == url.standardizedFileURL }
        case .tag(let tag): list = list.filter { $0.meta.tags.contains(tag) }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter { $0.meta.title.localizedCaseInsensitiveContains(q) || $0.meta.searchText.localizedCaseInsensitiveContains(q) }
        }
        return list.sorted { a, b in
            if a.meta.pinned != b.meta.pinned { return a.meta.pinned }
            return a.meta.modified > b.meta.modified
        }
    }

    var tagCounts: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for n in notes { for t in n.meta.tags { counts[t, default: 0] += 1 } }
        return counts.map { ($0.key, $0.value) }.sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    func noteCount(in folder: URL) -> Int {
        notes.filter { $0.folderURL.standardizedFileURL == folder.standardizedFileURL }.count
    }

    func relativeFolderName(_ url: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        return p.hasPrefix(root) ? String(p.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : url.lastPathComponent
    }

    var allFolderURLs: [URL] {
        var out: [URL] = []
        func walk(_ nodes: [FolderNode]) { for n in nodes { out.append(n.url); walk(n.children ?? []) } }
        walk(folders)
        return out
    }

    /// Folder for new notes: the selected folder, else the default one.
    var targetFolder: URL {
        if case .folder(let url) = sidebarSelection { return url }
        if let current = currentDocument { return current.url.deletingLastPathComponent() }
        let def = rootURL.appendingPathComponent(Self.defaultFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: def, withIntermediateDirectories: true)
        return def
    }

    // MARK: Notes

    @discardableResult
    func createNote(in folder: URL? = nil, initialTag: String? = nil) -> NoteRef? {
        let dir = folder ?? targetFolder
        var meta = NoteMetadata()
        meta.title = "Neue Notiz"
        var body = NoteBody()
        if let tag = initialTag {
            var b = BlockRecord(kind: .text)
            let s = NSMutableAttributedString(string: "\n#\(tag)", attributes: ThemeManager.shared.bodyAttributes)
            b.rtf = RichTextCodec.rtfData(from: s)
            body.blocks = [b]
        }
        let file = NoteFile(meta: meta, body: body)
        let url = uniqueURL(in: dir, base: "Neue Notiz")
        do {
            try file.write(to: url)
        } catch {
            lastError = "Notiz konnte nicht angelegt werden: \(error.localizedDescription)"
            return nil
        }
        let ref = NoteRef(meta: meta, url: url)
        notes.append(ref)
        if case .pinned = sidebarSelection ?? .all { sidebarSelection = .all }
        selectedNoteID = ref.id
        return ref
    }

    func write(_ imported: [ImportedNote]) -> Int {
        var count = 0
        for note in imported {
            var dir = rootURL
            for component in note.folderPath { dir.appendPathComponent(Self.sanitize(component), isDirectory: true) }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = uniqueURL(in: dir, base: Self.sanitize(note.file.meta.title.isEmpty ? "Notiz" : note.file.meta.title))
            do {
                try note.file.write(to: url)
                count += 1
            } catch {
                lastError = "Import von „\(note.file.meta.title)“ fehlgeschlagen: \(error.localizedDescription)"
            }
        }
        reload()
        return count
    }

    private func openSelected() {
        if let doc = currentDocument {
            doc.saveNow()
        }
        guard let id = selectedNoteID, let ref = notes.first(where: { $0.id == id }) else {
            currentDocument = nil
            return
        }
        do {
            let file = try NoteFile.read(from: ref.url)
            let doc = NoteDocument(file: file, url: ref.url)
            doc.store = self
            currentDocument = doc
            AttachmentSync.syncExternalEdits(in: doc)
        } catch {
            lastError = "„\(ref.meta.title)“ konnte nicht geöffnet werden: \(error.localizedDescription)"
            currentDocument = nil
        }
    }

    func save(_ doc: NoteDocument) {
        let file = doc.makeFile()
        do {
            try file.write(to: doc.url)
        } catch {
            lastError = "Speichern fehlgeschlagen: \(error.localizedDescription)"
            return
        }
        renameIfNeeded(doc)
        if let i = notes.firstIndex(where: { $0.id == doc.id }) {
            notes[i] = NoteRef(meta: file.meta, url: doc.url)
        } else {
            notes.append(NoteRef(meta: file.meta, url: doc.url))
        }
    }

    /// Keeps file names readable: the file is named after the note's title.
    private func renameIfNeeded(_ doc: NoteDocument) {
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
        if let doc = currentDocument, doc.id == id {
            doc.setPinned(!doc.meta.pinned)
            doc.saveNow()
            return
        }
        guard let ref = notes.first(where: { $0.id == id }), var file = try? NoteFile.read(from: ref.url) else { return }
        file.meta.pinned.toggle()
        try? file.write(to: ref.url)
        if let i = notes.firstIndex(where: { $0.id == id }) { notes[i].meta = file.meta }
    }

    func delete(_ id: UUID) {
        guard let ref = notes.first(where: { $0.id == id }) else { return }
        if currentDocument?.id == id {
            currentDocument = nil
        }
        do {
            try FileManager.default.trashItem(at: ref.url, resultingItemURL: nil)
        } catch {
            lastError = "Löschen fehlgeschlagen: \(error.localizedDescription)"
            return
        }
        let list = filteredNotes
        let idx = list.firstIndex(where: { $0.id == id })
        notes.removeAll { $0.id == id }
        if selectedNoteID == id {
            let remaining = filteredNotes
            selectedNoteID = idx.flatMap { remaining.indices.contains($0) ? remaining[$0].id : remaining.last?.id }
        }
    }

    func move(_ id: UUID, to folder: URL) {
        guard let ref = notes.first(where: { $0.id == id }),
              ref.folderURL.standardizedFileURL != folder.standardizedFileURL else { return }
        if let doc = currentDocument, doc.id == id { doc.saveNow() }
        let target = uniqueURL(in: folder, base: ref.url.deletingPathExtension().lastPathComponent)
        do {
            try FileManager.default.moveItem(at: ref.url, to: target)
        } catch {
            lastError = "Verschieben fehlgeschlagen: \(error.localizedDescription)"
            return
        }
        if let i = notes.firstIndex(where: { $0.id == id }) { notes[i].url = target }
        if let doc = currentDocument, doc.id == id { doc.url = target }
    }

    // MARK: Folders

    @discardableResult
    func createFolder(named name: String, in parent: URL? = nil) -> URL? {
        let dir = (parent ?? rootURL).appendingPathComponent(Self.sanitize(name), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        } catch {
            lastError = "Ordner konnte nicht angelegt werden: \(error.localizedDescription)"
            return nil
        }
        reload()
        sidebarSelection = .folder(dir)
        return dir
    }

    func renameFolder(_ url: URL, to name: String) {
        let target = url.deletingLastPathComponent().appendingPathComponent(Self.sanitize(name), isDirectory: true)
        guard target != url else { return }
        currentDocument?.saveNow()
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            lastError = "Umbenennen fehlgeschlagen: \(error.localizedDescription)"
            return
        }
        if let doc = currentDocument, doc.url.path.hasPrefix(url.path + "/") {
            doc.url = URL(fileURLWithPath: target.path + doc.url.path.dropFirst(url.path.count))
        }
        reload()
        sidebarSelection = .folder(target)
    }

    func deleteFolder(_ url: URL) {
        if let doc = currentDocument, doc.url.path.hasPrefix(url.path + "/") {
            currentDocument = nil
            selectedNoteID = nil
        }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            lastError = "Ordner konnte nicht gelöscht werden: \(error.localizedDescription)"
        }
        sidebarSelection = .all
        reload()
    }

    // MARK: Helpers

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0").union(.newlines).union(.controlCharacters)
        var s = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "Ohne Titel" }
        return String(s.prefix(80))
    }

    private func uniqueURL(in dir: URL, base: String) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(base).appendingPathExtension(FolioArchive.fileExtension)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(FolioArchive.fileExtension)
            n += 1
        }
        return url
    }
}

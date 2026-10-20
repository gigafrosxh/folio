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
    /// Folio's own trash (deleted notes and folders).
    case trash
    /// Note files that could not be read.
    case damaged
}

/// A note file that cannot be opened, with what the diagnosis found and could rescue.
struct DamagedNote: Identifiable {
    var url: URL
    var report: DiagnosticReport
    var id: URL { url }
}

/// The open note was changed outside Folio while it had unsaved edits.
struct NoteConflict: Identifiable {
    let id = UUID()
    var doc: NoteDocument
    /// The file as it is on disk now (nil when it was deleted).
    var diskData: Data?
    var diskFile: NoteFile?
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
    /// Items in Folio's trash.
    @Published private(set) var trashItems: [TrashItem] = []
    /// Note files in the library that cannot be read at all.
    @Published private(set) var damagedNotes: [DamagedNote] = []
    /// The selected note could not be opened; the editor shows the diagnosis instead.
    @Published private(set) var openFailure: DamagedNote?
    /// An external change collided with unsaved edits; the window asks what to do.
    @Published var conflict: NoteConflict?

    var history: NoteHistory { NoteHistory(library: rootURL) }
    var trash: LibraryTrash { LibraryTrash(library: rootURL) }
    private var watchTimer: Timer?

    static let defaultFolderName = "Notizen"

    private init() {
        // FOLIO_LIBRARY overrides the library folder (used for debugging without touching real notes).
        let path = ProcessInfo.processInfo.environment["FOLIO_LIBRARY"] ?? ThemeManager.shared.settings.libraryPath
        rootURL = URL(fileURLWithPath: path, isDirectory: true)
        prepareRoot()
        reload()
        purgeTrash()
        // Notices when another app or a sync service changes the open note.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { NoteStore.shared.checkExternalChange() }
        }
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
        purgeTrash()
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
        var damaged: [DamagedNote] = []
        func scan(_ dir: URL) -> [FolderNode] {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
            var nodes: [FolderNode] = []
            for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                if item.pathExtension == FolioArchive.fileExtension {
                    if let meta = try? NoteFile.readMetadata(at: item) { found.append(NoteRef(meta: meta, url: item)) }
                    else { damaged.append(DamagedNote(url: item, report: FolioDiagnostics.diagnose(at: item))) }
                } else if values?.isDirectory == true && values?.isPackage != true {
                    let children = scan(item)
                    nodes.append(FolderNode(url: item, name: item.lastPathComponent, children: children.isEmpty ? nil : children))
                }
            }
            return nodes
        }
        folders = scan(rootURL)
        notes = found
        damagedNotes = damaged
        trashItems = trash.items()
        if sidebarSelection == .damaged, damaged.isEmpty { sidebarSelection = .all }
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
        case .trash, .damaged: list = []
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
            // Closing a note ends its shared code sessions (variables of linked code blocks).
            if doc.id != selectedNoteID { KernelManager.shared.shutdown(note: doc.id) }
        }
        openFailure = nil
        guard let id = selectedNoteID, let ref = notes.first(where: { $0.id == id }) else {
            currentDocument = nil
            return
        }
        open(ref.url)
    }

    /// Loads a note into the editor. A file that cannot be decoded is diagnosed instead of opened.
    private func open(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            openFailure = DamagedNote(url: url, report: FolioDiagnostics.diagnose(at: url))
            currentDocument = nil
            return
        }
        do {
            let file = try NoteFile.decode(data)
            let doc = NoteDocument(file: file, url: url)
            doc.store = self
            doc.diskFingerprint = FileFingerprint(data: data)
            currentDocument = doc
            AttachmentSync.syncExternalEdits(in: doc)
            // The state on disk before any edit is always in the history.
            recordVersion(data, noteID: file.meta.id, force: true)
        } catch {
            openFailure = DamagedNote(url: url, report: FolioDiagnostics.diagnose(data))
            currentDocument = nil
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

    /// Moves a note into Folio's trash (restorable; its versions are kept).
    func delete(_ id: UUID) {
        guard let ref = notes.first(where: { $0.id == id }) else { return }
        if let doc = currentDocument, doc.id == id {
            doc.saveNow()
            currentDocument = nil
        }
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
        currentDocument?.saveNow()
        do {
            try trash.moveToTrash(url)
        } catch {
            lastError = "Ordner konnte nicht gelöscht werden: \(error.localizedDescription)"
        }
        sidebarSelection = .all
        reload()
    }

    // MARK: Trash

    func restore(_ item: TrashItem) {
        do {
            let url = try trash.restore(item)
            reload()
            if item.isFolder {
                sidebarSelection = .folder(url)
            } else if let ref = notes.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                sidebarSelection = .all
                selectedNoteID = ref.id
            }
        } catch {
            lastError = "Wiederherstellen fehlgeschlagen: \(error.localizedDescription)"
            trashItems = trash.items()
        }
    }

    func deletePermanently(_ item: TrashItem) {
        do { try trash.deletePermanently(item, history: history) } catch {
            lastError = "Endgültiges Löschen fehlgeschlagen: \(error.localizedDescription)"
        }
        trashItems = trash.items()
    }

    func emptyTrash() {
        trash.empty(history: history)
        trashItems = trash.items()
    }

    /// Items older than the setting (30 days by default) leave the trash for good.
    private func purgeTrash() {
        let days = ThemeManager.shared.settings.trashRetentionDays
        if days > 0, trash.purge(olderThan: days, history: history) > 0 { trashItems = trash.items() }
    }

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
            reloadCurrent(from: doc.url)
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

    /// Reopens the current note from disk (after a restore or when taking the external version).
    private func reloadCurrent(from url: URL) {
        if let doc = currentDocument { KernelManager.shared.shutdown(note: doc.id) }
        currentDocument = nil
        open(url)
        if let doc = currentDocument, let i = notes.firstIndex(where: { $0.id == doc.id }) {
            notes[i] = NoteRef(meta: doc.meta, url: url)
        }
    }

    // MARK: External changes

    /// Called every few seconds and when Folio becomes active.
    func checkExternalChange() {
        guard let doc = currentDocument, conflict == nil, let expected = doc.diskFingerprint else { return }
        guard let current = FileFingerprint.of(doc.url) else { return }   // moved/deleted: the next save recreates it
        guard current != expected else { return }
        if doc.isDirty {
            raiseConflict(doc)
        } else {
            // No unsaved edits here: follow the other app's version (our state stays in the history).
            reloadCurrent(from: doc.url)
        }
    }

    private func raiseConflict(_ doc: NoteDocument) {
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
            reloadCurrent(from: doc.url)
        case .keepBoth:
            let stamp = Date().formatted(date: .numeric, time: .shortened).replacingOccurrences(of: ":", with: ".")
            saveAsNewNote(mine, in: doc.url.deletingLastPathComponent(), suffix: "(Konflikt \(stamp))")
            reloadCurrent(from: doc.url)
        }
        if currentDocument == nil, conflict.diskData == nil { reload() }
    }

    // MARK: Damaged notes

    /// Saves what could be rescued as a new note and moves the damaged file aside (never deletes it).
    func salvage(_ damaged: DamagedNote) {
        guard let file = damaged.report.salvagedFile() else { return }
        let url = uniqueURL(in: damaged.url.deletingLastPathComponent(), base: Self.sanitize(file.meta.title))
        do {
            try file.write(to: url)
            try quarantine(damaged.url)
        } catch {
            lastError = "Retten fehlgeschlagen: \(error.localizedDescription)"
            return
        }
        openFailure = nil
        reload()
        sidebarSelection = .all
        selectedNoteID = file.meta.id
    }

    /// Restores the newest intact version of a damaged note in place (the damaged file is kept aside).
    func restoreLatestVersion(_ damaged: DamagedNote) {
        guard let id = damaged.report.meta?.id, let version = history.versions(of: id).first(where: { (try? history.read($0)) != nil }),
              var file = try? history.read(version) else { return }
        do {
            try quarantine(damaged.url)
            file.meta.modified = Date()
            try file.write(to: damaged.url)
        } catch {
            lastError = "Wiederherstellen fehlgeschlagen: \(error.localizedDescription)"
            return
        }
        openFailure = nil
        reload()
        selectedNoteID = nil
        selectedNoteID = id
    }

    /// The newest readable version of a damaged note, if the history has one.
    func latestIntactVersion(of damaged: DamagedNote) -> NoteVersion? {
        guard let id = damaged.report.meta?.id else { return nil }
        return history.versions(of: id).first { (try? history.read($0)) != nil }
    }

    /// Damaged originals go to `.folio/damaged/`, so they can still be examined or sent in.
    private func quarantine(_ url: URL) throws {
        let dir = LibraryData.folder(rootURL, "damaged")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent(Stamp.string(Date()) + "-" + url.lastPathComponent))
    }

    var quarantineFolder: URL { LibraryData.folder(rootURL, "damaged") }

    // MARK: Helpers

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0").union(.newlines).union(.controlCharacters)
        var s = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "Ohne Titel" }
        return String(s.prefix(80))
    }

    func uniqueURL(in dir: URL, base: String) -> URL {
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

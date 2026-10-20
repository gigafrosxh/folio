import AppKit
import Combine
import FolioCore
/// The note library: a folder tree on disk where every note is one `.folio` file.
/// Folders are real directories, so the library can be browsed, synced and backed up like any files.
@MainActor
final class NoteStore: ObservableObject {
    @Published var tagEdit: TagEditProgress?
    var templatesFolder: URL { LibraryData.folder(rootURL, "templates") }
    var quarantineFolder: URL { LibraryData.folder(rootURL, "damaged") }
    static let shared = NoteStore()

    @Published internal(set) var rootURL: URL
    @Published internal(set) var folders: [FolderNode] = []
    @Published internal(set) var notes: [NoteRef] = [] { didSet { notesVersion += 1 } }
    @Published var sidebarSelection: SidebarItem? = .all {
        didSet { if oldValue != sidebarSelection, let id = selectedNoteID, !filteredNotes.contains(where: { $0.id == id }) { selectedNoteID = filteredNotes.first?.id } }
    }
    /// The note of the active tab in the main window.
    @Published var selectedNoteID: UUID? {
        didSet { if oldValue != selectedNoteID { openSelected(replacing: oldValue) } }
    }
    /// Open notes, shared by tabs, the split view and note windows (one document per note).
    @Published internal(set) var documents: [UUID: NoteDocument] = [:]
    /// Tabs of the main window (note ids, left to right).
    @Published internal(set) var tabs: [UUID] = []
    /// Note shown on the right of the split view.
    @Published var splitNoteID: UUID? {
        didSet {
            if let id = splitNoteID { ensureLoaded(id) }
            releaseUnused()
        }
    }
    /// Notes open in their own windows.
    @Published internal(set) var windowNoteIDs: [UUID] = []
    /// The note whose editor had focus last (menus and shortcuts act on it).
    @Published var focusedNoteID: UUID?
    /// Notes that could not be opened, with their diagnosis.
    @Published internal(set) var failures: [UUID: DamagedNote] = [:]
    /// The next selection opens a new tab instead of replacing the active one.
    var nextSelectionInNewTab = false

    /// The note being worked on: the focused editor's note, else the active tab's.
    var currentDocument: NoteDocument? {
        if let f = focusedNoteID, let d = documents[f], isOnScreen(f) { return d }
        return selectedNoteID.flatMap { documents[$0] }
    }

    /// Saves every open note (before quitting, updating, backing up).
    func saveAll() { for doc in documents.values { doc.saveNow() } }

    /// Like `isVisible`, but focus mode hides the split view, so its note cannot receive commands then.
    func isOnScreen(_ id: UUID) -> Bool {
        if UserDefaults.standard.bool(forKey: "folio.focusMode") { return id == selectedNoteID || windowNoteIDs.contains(id) }
        return isVisible(id)
    }

    func isVisible(_ id: UUID) -> Bool { id == selectedNoteID || id == splitNoteID || windowNoteIDs.contains(id) }
    @Published var searchText = ""
    /// Filters chosen in the search filter menu (combined with typed `tag:` … filters).
    @Published var searchFilter = SearchFilter()
    /// Searching looks through the whole library, not only the selected folder or tag.
    @Published var searchEverywhere = UserDefaults.standard.object(forKey: "folio.searchEverywhere") as? Bool ?? true {
        didSet { UserDefaults.standard.set(searchEverywhere, forKey: "folio.searchEverywhere") }
    }
    /// A selected folder also shows the notes of its subfolders.
    @Published var includeSubfolders = UserDefaults.standard.bool(forKey: "folio.includeSubfolders") {
        didSet { UserDefaults.standard.set(includeSubfolders, forKey: "folio.includeSubfolders") }
    }
    /// Recently opened notes, newest first.
    @Published internal(set) var recent: RecentList = {
        if let d = UserDefaults.standard.data(forKey: "folio.recent"), let r = try? JSONDecoder().decode(RecentList.self, from: d) { return r }
        return RecentList()
    }() {
        didSet { if let d = try? JSONEncoder().encode(recent) { UserDefaults.standard.set(d, forKey: "folio.recent") } }
    }
    /// Note templates.
    @Published internal(set) var templates: [NoteRef] = []
    /// Symbolic links in the library that were not followed (outside the library or a loop) (#56).
    @Published internal(set) var skippedLinks: [String] = []
    let scanner = LibraryScanner()
    /// Last result of `filteredNotes` and what it was computed from (it is read on every redraw) (#62).
    var filterMemo: (key: String, notes: [NoteRef])?
    var notesVersion = 0
    /// Block kinds of notes saved before 0.15 (read once, when a type filter needs them).
    var kindsCache: [URL: [String]] = [:]
    @Published var lastError: String?
    /// Items in Folio's trash.
    @Published internal(set) var trashItems: [TrashItem] = []
    /// Note files in the library that cannot be read at all.
    @Published internal(set) var damagedNotes: [DamagedNote] = []
    /// The selected note could not be opened; the editor shows the diagnosis instead.
    var openFailure: DamagedNote? { selectedNoteID.flatMap { failures[$0] } }
    /// An external change collided with unsaved edits; the window asks what to do.
    @Published var conflict: NoteConflict?

    var history: NoteHistory { NoteHistory(library: rootURL) }
    var trash: LibraryTrash { LibraryTrash(library: rootURL) }
    var watchTimer: Timer?

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
        for doc in documents.values { doc.saveNow() }
        tabs = []
        splitNoteID = nil
        selectedNoteID = nil
        closeAllDocuments()
        AIChatModel.resetCache()
        rootURL = url
        scanner.clearCache()
        ThemeManager.shared.settings.libraryPath = url.path
        prepareRoot()
        reload()
        purgeTrash()
    }

    func prepareRoot() {
        let fm = FileManager.default
        try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let defaultFolder = rootURL.appendingPathComponent(Self.defaultFolderName, isDirectory: true)
        if (try? fm.contentsOfDirectory(atPath: rootURL.path))?.filter({ !$0.hasPrefix(".") }).isEmpty ?? true {
            try? fm.createDirectory(at: defaultFolder, withIntermediateDirectories: true)
        }
    }

    func reload() {
        let result = scanner.scan(rootURL)
        func nodes(_ fs: [LibraryScanner.Folder]) -> [FolderNode] {
            fs.map { FolderNode(url: $0.url, name: $0.name, children: $0.children.isEmpty ? nil : nodes($0.children)) }
        }
        folders = nodes(result.folders)
        notes = result.notes.map { NoteRef(meta: $0.meta, url: $0.url) }
        let damaged = result.unreadable.map { DamagedNote(url: $0, report: FolioDiagnostics.diagnose(at: $0)) }
        damagedNotes = damaged
        skippedLinks = result.skippedLinks.map { "\($0.url.lastPathComponent): \($0.reason)" }
        trashItems = trash.items()
        templates = Self.scanTemplates(LibraryData.folder(rootURL, "templates"))
        if sidebarSelection == .damaged, damaged.isEmpty { sidebarSelection = .all }
        let known = Set(notes.map(\.id)).union(templates.map(\.id))
        if let id = selectedNoteID, !known.contains(id) { selectedNoteID = nil }
        tabs.removeAll { !known.contains($0) }
        if let s = splitNoteID, !known.contains(s) { splitNoteID = nil }
        releaseUnused()
    }

    // MARK: Queries

    /// The search as typed plus the filter menu.
    var activeSearch: SearchFilter { SearchFilter.parse(searchText).merged(with: searchFilter) }
    var isSearching: Bool { !activeSearch.isEmpty }

    var filteredNotes: [NoteRef] {
        let key = "\(notesVersion)|\(String(describing: sidebarSelection))|\(searchText)|\(String(describing: searchFilter))|\(searchEverywhere)|\(includeSubfolders)|\(templates.count)"
        if let memo = filterMemo, memo.key == key { return memo.notes }
        let result = computeFilteredNotes()
        filterMemo = (key, result)
        return result
    }

    func computeFilteredNotes() -> [NoteRef] {
        if sidebarSelection == .templates { return templates.sorted { $0.meta.title.localizedStandardCompare($1.meta.title) == .orderedAscending } }
        var list = notes
        let search = activeSearch
        if !(search.isEmpty == false && searchEverywhere) {
            switch sidebarSelection ?? .all {
            case .all: break
            case .pinned: list = list.filter(\.meta.pinned)
            case .folder(let url): list = list.filter { isInFolder($0.folderURL, url) }
            case .tag(let tag): list = list.filter { $0.meta.tags.contains(tag) }
            case .trash, .damaged, .templates: list = []
            }
        }
        if !search.isEmpty {
            let root = rootURL.standardizedFileURL.path
            list = list.filter { ref in
                let folder = ref.folderURL.standardizedFileURL.path
                let rel = folder.hasPrefix(root) ? String(folder.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : ref.folderURL.lastPathComponent
                return search.matches(ref.meta, folderPath: rel,
                                      kinds: search.types.isEmpty || ref.meta.kinds != nil ? nil : kinds(of: ref),
                                      haystack: ref.haystack)
            }
        }
        return list.sorted { a, b in
            if a.meta.pinned != b.meta.pinned { return a.meta.pinned }
            return a.meta.modified > b.meta.modified
        }
    }

    /// Whether `noteFolder` is `folder` itself or (with "include subfolders") below it.
    func isInFolder(_ noteFolder: URL, _ folder: URL) -> Bool {
        let a = noteFolder.standardizedFileURL.path, b = folder.standardizedFileURL.path
        return a == b || (includeSubfolders && a.hasPrefix(b + "/"))
    }

    func kinds(of ref: NoteRef) -> [String] {
        if let k = kindsCache[ref.url] { return k }
        let k = (try? NoteFile.read(from: ref.url)).map { Array(Set($0.body.blocks.map(\.kind.rawValue))) } ?? []
        kindsCache[ref.url] = k
        return k
    }

    var tagCounts: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for n in notes { for t in n.meta.tags { counts[t, default: 0] += 1 } }
        return counts.map { ($0.key, $0.value) }.sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    func noteCount(in folder: URL) -> Int {
        notes.filter { isInFolder($0.folderURL, folder) }.count
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

    func openSelected(replacing old: UUID?) {
        documents[old ?? UUID()]?.saveNow()
        guard let id = selectedNoteID else {
            if let old, let i = tabs.firstIndex(of: old) { tabs.remove(at: i) }
            releaseUnused()
            return
        }
        // Like Xcode: clicking a note replaces the active tab, unless it is already open in a tab.
        if !tabs.contains(id) {
            if !nextSelectionInNewTab, let old, let i = tabs.firstIndex(of: old) { tabs[i] = id } else { tabs.append(id) }
        }
        nextSelectionInNewTab = false
        failures[id] = nil
        ensureLoaded(id)
        focusedNoteID = id
        if notes.contains(where: { $0.id == id }) { recent.opened(id) }
        releaseUnused()
    }

    /// Loads a note unless it is open already.
    func ensureLoaded(_ id: UUID) {
        guard documents[id] == nil, let ref = notes.first(where: { $0.id == id }) ?? templates.first(where: { $0.id == id }) else { return }
        open(ref.url, id: id)
    }

    func document(for id: UUID?) -> NoteDocument? { id.flatMap { documents[$0] } }

    /// Saves and closes documents no tab, split view or window shows any more.
    func releaseUnused() {
        for (id, doc) in documents where !isVisible(id) && !tabs.contains(id) {
            doc.saveNow()
            // Closing a note ends its shared code sessions (variables of linked code blocks) and terminal.
            KernelManager.shared.shutdown(note: id)
            TerminalSession.close(note: id)
            documents[id] = nil
        }
    }

    func closeAllDocuments() {
        for (id, doc) in documents { doc.saveNow(); KernelManager.shared.shutdown(note: id) }
        documents = [:]
        failures = [:]
    }

    /// Closes a note everywhere (it was deleted or moved away).
    func closeDocument(_ id: UUID) {
        if let doc = documents[id] { doc.saveNow(); KernelManager.shared.shutdown(note: id) }
        documents[id] = nil
        tabs.removeAll { $0 == id }
        if splitNoteID == id { splitNoteID = nil }
        windowNoteIDs.removeAll { $0 == id }
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
        for doc in documents.values { doc.saveNow() }
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            lastError = "Umbenennen fehlgeschlagen: \(error.localizedDescription)"
            return
        }
        for doc in documents.values where doc.url.path.hasPrefix(url.path + "/") {
            doc.url = URL(fileURLWithPath: target.path + doc.url.path.dropFirst(url.path.count))
        }
        reload()
        sidebarSelection = .folder(target)
    }

    func deleteFolder(_ url: URL) {
        for doc in documents.values { doc.saveNow() }
        let inside = documents.values.filter { $0.url.path.hasPrefix(url.path + "/") }.map(\.id)
        if let sel = selectedNoteID, inside.contains(sel) { selectedNoteID = nil }
        for id in inside { closeDocument(id) }
        do {
            try trash.moveToTrash(url)
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

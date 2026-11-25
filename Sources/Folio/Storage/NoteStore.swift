import AppKit
import Combine
import FolioCore
/// The note library: a folder tree on disk where every note is one `.folio` file.
/// Its state is changed only by `NoteStore` and its extensions (the `NoteStore+…` files); the views read it (#335).
/// Folders are real directories, so the library can be browsed, synced and backed up like any files.
@MainActor
final class NoteStore: ObservableObject {
    @Published var tagEdit: TagEditProgress?
    var templatesFolder: URL { LibraryData.folder(rootURL, "templates") }
    var quarantineFolder: URL { LibraryData.folder(rootURL, "damaged") }
    static let shared = NoteStore()

    @Published var rootURL: URL
    @Published var folders: [FolderNode] = [] {
        didSet { libraryVersion += 1 }
    }
    @Published var notes: [NoteRef] = [] {
        didSet {
            notesVersion += 1
            libraryVersion += 1
            refreshLinkIndex()
        }
    }
    @Published var sidebarSelection: SidebarItem? = .all {
        didSet { if oldValue != sidebarSelection, let id = selectedNoteID, !filteredNotes.contains(where: { $0.id == id }) { selectedNoteID = filteredNotes.first?.id } }
    }
    /// The note of the active tab in the main window.
    @Published var selectedNoteID: UUID? {
        didSet { if oldValue != selectedNoteID { openSelected(replacing: oldValue) } }
    }
    /// Open notes, shared by tabs, the split view and note windows (one document per note).
    @Published var documents: [UUID: NoteDocument] = [:]
    /// Large notes being read in the background (#388).
    @Published var loadingNotes: Set<UUID> = []
    /// Tabs of the main window (note ids, left to right).
    @Published var tabs: [UUID] = []
    /// Note shown on the right of the split view.
    @Published var splitNoteID: UUID? {
        didSet {
            if let id = splitNoteID { ensureLoaded(id) }
            releaseUnused()
        }
    }
    /// Notes open in their own windows.
    @Published var windowNoteIDs: [UUID] = []
    /// The note whose editor had focus last (menus and shortcuts act on it).
    @Published var focusedNoteID: UUID?
    /// Notes that could not be opened, with their diagnosis.
    @Published var failures: [UUID: DamagedNote] = [:]
    /// The next selection opens a new tab instead of replacing the active one.
    var nextSelectionInNewTab = false

    /// The note being worked on: the focused editor's note, else the active tab's.
    var currentDocument: NoteDocument? {
        if let f = focusedNoteID, let d = documents[f], isOnScreen(f) { return d }
        return selectedNoteID.flatMap { documents[$0] }
    }

    /// Saves every open note (before quitting, updating, backing up).
    func saveAll() { for doc in documents.values { doc.saveNow() } }

    /// Saves every open note (or those `matching`) and returns the ones whose changes could still not be written.
    /// Callers that would close or replace notes stop when this is not empty (#189–#193).
    func unsavedAfterSaving(_ matching: (NoteDocument) -> Bool = { _ in true }) -> [NoteDocument] {
        let docs = documents.values.filter(matching)
        for doc in docs { doc.saveNow() }
        return docs.filter(\.isDirty)
    }

    /// Titles for a message about unsaved notes.
    static func titles(_ docs: [NoteDocument]) -> String {
        docs.map { "„\($0.meta.title.isEmpty ? "Neue Notiz" : $0.meta.title)“" }.joined(separator: ", ")
    }

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
    @Published var recent: RecentList = {
        if let d = UserDefaults.standard.data(forKey: "folio.recent"), let r = try? JSONDecoder().decode(RecentList.self, from: d) { return r }
        return RecentList()
    }()
    {
        didSet { if let d = try? JSONEncoder().encode(recent) { UserDefaults.standard.set(d, forKey: "folio.recent") } }
    }
    /// Note templates.
    @Published var templates: [NoteRef] = [] {
        didSet { libraryVersion += 1 }
    }
    /// Symbolic links in the library that were not followed (outside the library or a loop) (#56).
    @Published var skippedLinks: [String] = []
    let scanner = LibraryScanner()
    /// Counts reloads; a background read that is not the newest one is dropped (#220).
    var reloadGeneration = 0
    /// Counts changes to notes, folders, templates and trash; a background read that began before one is outdated (#362).
    var libraryVersion = 0
    /// How long applying the last reload took on the main thread (benchmark #219/#220).
    var lastApplyMs = 0.0
    /// Last result of `filteredNotes` and what it was computed from (it is read on every redraw) (#62).
    var filterMemo: (key: String, notes: [NoteRef])?
    /// Notes per folder (direct, and with subfolders), counted once per change of the note list instead of once per
    /// folder on every sidebar redraw – that took half of the main thread while typing (#374).
    var folderCountMemo: (version: Int, direct: [String: Int], nested: [String: Int])?
    var notesVersion = 0
    /// Links between notes (#119), updated per changed note when `notes` changes.
    var linkIndex = LinkIndex()
    /// What each note looked like when it went into `linkIndex`.
    var linkIndexStamps: [UUID: String] = [:]
    /// Block kinds of notes saved before 0.15 (read once, when a type filter needs them).
    var kindsCache: [URL: [String]] = [:]
    @Published var lastError: String?
    /// Order, favorites and smart views of this library (#13, #14, #15), saved in `.folio/organization.json`.
    @Published var organization = LibraryOrganization() {
        didSet {
            guard organization != oldValue else { return }
            organizationVersion += 1
            if organization.folderOrder != oldValue.folderOrder { folders = orderedFolders(folders, parent: "") }
            saveOrganization()
        }
    }
    var organizationVersion = 0
    /// Set while the library's organization is read, so reading does not write it back.
    var loadingOrganization = false
    /// The organization file as Folio last read or wrote it; anything else on disk was changed by someone else (#175).
    var organizationOnDisk: Data?
    /// Items in Folio's trash.
    @Published var trashItems: [TrashItem] = [] {
        didSet { libraryVersion += 1 }
    }
    /// Note files in the library that cannot be read at all.
    @Published var damagedNotes: [DamagedNote] = []
    /// The selected note could not be opened; the editor shows the diagnosis instead.
    var openFailure: DamagedNote? { selectedNoteID.flatMap { failures[$0] } }
    /// An external change collided with unsaved edits; the window asks what to do.
    @Published var conflict: NoteConflict?

    var history: NoteHistory { NoteHistory(library: rootURL) }
    var trash: LibraryTrash { LibraryTrash(library: rootURL) }
    var watchTimer: Timer?

    static let defaultFolderName = LibraryFiles.defaultFolderName

    private init() {
        // FOLIO_LIBRARY overrides the library folder (used for debugging without touching real notes).
        let path = ProcessInfo.processInfo.environment["FOLIO_LIBRARY"] ?? ThemeManager.shared.settings.libraryPath
        rootURL = URL(fileURLWithPath: path, isDirectory: true)
        prepareRoot()
        loadOrganization()
        reload()
        purgeTrash()
        // Notices when another app or a sync service changes the open note.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { NoteStore.shared.checkExternalChange() }
        }
    }

    // MARK: Library

    /// Switches to another library folder. Refused while open notes cannot be saved, or their changes would be
    /// lost with the switch (#190).
    @discardableResult
    func setLibrary(_ url: URL) -> Bool {
        let unsaved = unsavedAfterSaving()
        guard unsaved.isEmpty else {
            lastError =
                "Die Bibliothek wurde nicht gewechselt: \(Self.titles(unsaved)) konnte nicht gesichert werden. "
                + "Sichere die Notiz zuerst (oder kopiere den Text), dann versuche es erneut."
            return false
        }
        tabs = []
        splitNoteID = nil
        selectedNoteID = nil
        closeAllDocuments()
        AIChatModel.resetCache()
        rootURL = url
        scanner.clearCache()
        ThemeManager.shared.settings.libraryPath = url.path
        prepareRoot()
        loadOrganization()
        reloadInBackground()
        purgeTrash()
        return true
    }

    /// File-system side of the library (#216).
    var files: LibraryFiles { LibraryFiles(root: rootURL) }

    func prepareRoot() { files.prepare() }

    /// Everything a reload reads from disk; built off the main thread by `reloadInBackground` (#220).
    struct LibrarySnapshot: @unchecked Sendable {
        var root: URL
        var scan: LibraryScanner.Result
        /// Built here too: each ref lowercases its note's text for the search, which is the costly part (#220).
        var refs: [NoteRef]
        var damaged: [DamagedNote]
        var trash: [TrashItem]
        var templates: [NoteRef]
    }

    nonisolated static func readLibrary(_ root: URL, scanner: LibraryScanner) -> LibrarySnapshot {
        LibraryFiles(root: root).read(scanner: scanner)
    }

    /// Reads the library now. Callers that use the notes right afterwards need this; everything else should use
    /// `reloadInBackground`, which keeps the main thread free while the disk is read (#220).
    func reload() {
        reloadGeneration += 1
        apply(Self.readLibrary(rootURL, scanner: scanner))
    }

    /// Reads the library off the main thread and applies the result there. Only the newest read is applied, and only
    /// while the library is still the same, so quick changes never leave an older state behind.
    /// A read that started before a note was created, duplicated or deleted would undo that in the list, close
    /// its tab and drop the selection, so it is read again instead (#362).
    @discardableResult
    func reloadInBackground(attempt: Int = 0) -> Task<Void, Never> {
        reloadGeneration += 1
        let generation = reloadGeneration, version = libraryVersion, root = rootURL, scanner = self.scanner
        return Task {
            let snapshot = await Task.detached(priority: .userInitiated) { NoteStore.readLibrary(root, scanner: scanner) }.value
            switch Self.reloadOutcome(started: (generation, version, root), now: (reloadGeneration, libraryVersion, rootURL), attempt: attempt) {
            case .apply: apply(snapshot)
            case .drop: return
            case .readAgain: await reloadInBackground(attempt: attempt + 1).value
            case .readNow: reload()
            }
        }
    }

    enum ReloadOutcome: Equatable { case apply, drop, readAgain, readNow }

    /// What to do with a finished background read: a newer read or another library wins; changed lists mean the read
    /// is outdated and is repeated (after two tries synchronously, so constant edits cannot starve it) (#362).
    nonisolated static func reloadOutcome(
        started: (generation: Int, version: Int, root: URL), now: (generation: Int, version: Int, root: URL), attempt: Int
    ) -> ReloadOutcome {
        guard started.generation == now.generation, started.root == now.root else { return .drop }
        if started.version == now.version { return .apply }
        return attempt < 2 ? .readAgain : .readNow
    }

    private func apply(_ snapshot: LibrarySnapshot) {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { lastApplyMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000 }
        let result = snapshot.scan
        func nodes(_ fs: [LibraryScanner.Folder]) -> [FolderNode] {
            fs.map { FolderNode(url: $0.url, name: $0.name, children: $0.children.isEmpty ? nil : nodes($0.children)) }
        }
        folders = orderedFolders(nodes(result.folders), parent: "")
        notes = renewingDuplicateIDs(snapshot.refs)
        let damaged = snapshot.damaged
        damagedNotes = damaged
        skippedLinks = result.skippedLinks.map { "\($0.url.lastPathComponent): \($0.reason)" }
        trashItems = snapshot.trash
        templates = snapshot.templates
        if sidebarSelection == .damaged, damaged.isEmpty { sidebarSelection = .all }
        indexPDFsInLibrary()
        let known = Set(notes.map(\.id)).union(templates.map(\.id))
        if let id = selectedNoteID, !known.contains(id) { selectedNoteID = nil }
        tabs.removeAll { !known.contains($0) }
        if let s = splitNoteID, !known.contains(s) { splitNoteID = nil }
        releaseUnused()
    }

    /// Copies of a note file with the same id get a new identity, so each shows up as its own note (#166). The file
    /// Folio already knew under the id keeps it. A copy that cannot be rewritten stays hidden and is reported.
    private func renewingDuplicateIDs(_ found: [NoteRef]) -> [NoteRef] {
        let known = Dictionary(notes.map { ($0.id, $0.url) }, uniquingKeysWith: { a, _ in a })
        let (refs, failure) = files.renewingDuplicateIDs(found, known: known)
        if let failure { lastError = failure.localizedDescription }
        return refs
    }

    // MARK: Queries

    /// The search as typed plus the filter menu.
    var activeSearch: SearchFilter { SearchFilter.parse(searchText).merged(with: searchFilter) }
    var isSearching: Bool { !activeSearch.isEmpty }

    var filteredNotes: [NoteRef] {
        let key =
            "\(notesVersion)|\(String(describing: sidebarSelection))|\(searchText)|\(String(describing: searchFilter))|\(searchEverywhere)|\(includeSubfolders)|\(templates.count)|\(organizationVersion)"
        if let memo = filterMemo, memo.key == key { return memo.notes }
        let result = computeFilteredNotes()
        filterMemo = (key, result)
        return result
    }

    func computeFilteredNotes() -> [NoteRef] {
        if sidebarSelection == .templates { return templates.sorted { $0.meta.title.localizedStandardCompare($1.meta.title) == .orderedAscending } }
        let search = activeSearch
        var list = !search.isEmpty && searchEverywhere ? notes : selectionNotes()
        if !search.isEmpty { list = notesMatching(search, in: list) }
        return sorted(list)
    }

    /// The notes of the selected place in the sidebar, before any search.
    func selectionNotes() -> [NoteRef] {
        switch sidebarSelection ?? .all {
        case .all: return notes
        case .pinned: return notes.filter(\.meta.pinned)
        case .favorites: return notes.filter { organization.isFavorite($0.id) }
        case .smartView(let id): return smartViewNotes(id, in: notes)
        case .folder(let url): return notes.filter { isInFolder($0.folderURL, url) }
        case .tag(let tag): return notes.filter { $0.meta.tags.contains(tag) }
        case .trash, .damaged, .templates, .graph: return []
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
        let counts = folderCounts()
        let path = folder.standardizedFileURL.path
        return (includeSubfolders ? counts.nested : counts.direct)[path] ?? 0
    }

    private func folderCounts() -> (direct: [String: Int], nested: [String: Int]) {
        if let memo = folderCountMemo, memo.version == notesVersion { return (memo.direct, memo.nested) }
        var direct: [String: Int] = [:], nested: [String: Int] = [:]
        for note in notes {
            var path = note.folderURL.standardizedFileURL.path
            direct[path, default: 0] += 1
            // Every folder above the note counts it too (with subfolders), up to the root.
            while !path.isEmpty, path != "/" {
                nested[path, default: 0] += 1
                path = (path as NSString).deletingLastPathComponent
            }
        }
        folderCountMemo = (notesVersion, direct, nested)
        return (direct, nested)
    }

    func relativeFolderName(_ url: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        return p.hasPrefix(root) ? String(p.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : url.lastPathComponent
    }

    var allFolderURLs: [URL] {
        var out: [URL] = []
        func walk(_ nodes: [FolderNode]) {
            for n in nodes {
                out.append(n.url)
                walk(n.children ?? [])
            }
        }
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
        if let next = Self.selectionAfterCreatingNote(sidebarSelection) { sidebarSelection = next }
        // An empty new note matches no search; it would be missing from the list (#102).
        if isSearching {
            searchText = ""
            searchFilter = SearchFilter()
        }
        // Keys typed right after ⌘N belong to the new note, not to the search field (#100).
        FormattingController.shared.holdTypingForNewNote()
        selectedNoteID = ref.id
        return ref
    }

    /// Places that cannot show the new note in the editor (pinned list, graph, trash, damaged notes) switch to all
    /// notes, so ⌘N always opens the note with the cursor in it (#162). Nil keeps the selection.
    static func selectionAfterCreatingNote(_ selection: SidebarItem?) -> SidebarItem? {
        switch selection ?? .all {
        case .pinned, .graph, .trash, .damaged, .favorites, .smartView: return .all
        default: return nil
        }
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
    /// A large note (big attachments) is read and unpacked in the background; the editor shows a progress indicator
    /// meanwhile and the main thread stays free (#388). Small notes open right away, as before.
    func ensureLoaded(_ id: UUID) {
        guard documents[id] == nil, !loadingNotes.contains(id),
            let ref = notes.first(where: { $0.id == id }) ?? templates.first(where: { $0.id == id })
        else { return }
        let size = (try? ref.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > Self.backgroundOpenBytes else {
            open(ref.url, id: id)
            return
        }
        loadingNotes.insert(id)
        let url = ref.url
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> (Data, NoteFile)? in
                guard let data = try? Data(contentsOf: url), let file = try? NoteFile.decode(data) else { return nil }
                return (data, file)
            }.value
            loadingNotes.remove(id)
            // Closed or opened otherwise meanwhile: nothing to do.
            guard documents[id] == nil, isVisible(id) || tabs.contains(id) else { return }
            if let (data, file) = loaded {
                adopt(file, data: data, url: url, id: id)
            } else {
                open(url, id: id)  // reports the damage the usual way
            }
        }
    }

    /// Above this size a note opens in the background (#388).
    static let backgroundOpenBytes = 8 << 20

    func document(for id: UUID?) -> NoteDocument? { id.flatMap { documents[$0] } }

    /// Saves and closes documents no tab, split view or window shows any more.
    func releaseUnused() {
        for (id, doc) in documents where !isVisible(id) && !tabs.contains(id) {
            doc.saveNow()
            // A note that could not be saved stays open in a tab instead of being dropped with its changes (#183).
            if doc.isDirty {
                tabs.append(id)
                continue
            }
            // Closing a note ends its shared code sessions (variables of linked code blocks) and terminal.
            KernelManager.shared.shutdown(note: id)
            TerminalSession.close(note: id)
            documents[id] = nil
        }
    }

    func closeAllDocuments() {
        for (id, doc) in documents {
            doc.saveNow()
            KernelManager.shared.shutdown(note: id)
        }
        documents = [:]
        failures = [:]
    }

    /// Closes a note everywhere (it was deleted or moved away).
    func closeDocument(_ id: UUID) {
        if let doc = documents[id] {
            doc.saveNow()
            KernelManager.shared.shutdown(note: id)
        }
        documents[id] = nil
        tabs.removeAll { $0 == id }
        if splitNoteID == id { splitNoteID = nil }
        windowNoteIDs.removeAll { $0 == id }
    }

    // MARK: Folders

    @discardableResult
    func createFolder(named name: String, in parent: URL? = nil) -> URL? {
        let dir: URL
        switch files.createFolder(named: name, in: parent) {
        case .success(let url): dir = url
        case .failure(let failure):
            lastError = failure.localizedDescription
            return nil
        }
        reload()
        sidebarSelection = .folder(dir)
        return dir
    }

    func renameFolder(_ url: URL, to name: String) {
        guard url.deletingLastPathComponent().appendingPathComponent(Self.sanitize(name), isDirectory: true) != url else { return }
        for doc in documents.values { doc.saveNow() }
        // Taken while the folder still exists: paths of missing folders do not resolve the same way.
        let oldPath = relativeFolderName(url)
        let target: URL
        switch files.renameFolder(url, to: name) {
        case .success(let renamed): target = renamed
        case .failure(let failure):
            lastError = failure.localizedDescription
            return
        }
        for doc in documents.values where doc.url.path.hasPrefix(url.path + "/") {
            doc.url = URL(fileURLWithPath: target.path + doc.url.path.dropFirst(url.path.count))
        }
        organizationRenamedFolder(from: oldPath, to: relativeFolderName(target))
        reload()
        sidebarSelection = .folder(target)
    }

    func deleteFolder(_ url: URL) {
        // Notes inside with changes that cannot be saved keep the folder where it is (#192).
        let unsaved = unsavedAfterSaving { $0.url.path.hasPrefix(url.path + "/") }
        guard unsaved.isEmpty else {
            lastError = "Der Ordner wurde nicht gelöscht: \(Self.titles(unsaved)) hat Änderungen, die nicht gesichert werden konnten."
            return
        }
        for doc in documents.values { doc.saveNow() }
        let inside = documents.values.filter { $0.url.path.hasPrefix(url.path + "/") }.map(\.id)
        if case .failure(let failure) = files.trashFolder(url) {
            // Nothing was moved: the notes stay open as they are.
            lastError = failure.localizedDescription
            return
        }
        // Closed only once the folder really is in the trash.
        if let sel = selectedNoteID, inside.contains(sel) { selectedNoteID = nil }
        for id in inside { closeDocument(id) }
        sidebarSelection = .all
        reload()
    }

    // MARK: Helpers

    static func sanitize(_ name: String) -> String { LibraryFiles.sanitize(name) }

    func uniqueURL(in dir: URL, base: String) -> URL { LibraryFiles.uniqueURL(in: dir, base: base) }
}

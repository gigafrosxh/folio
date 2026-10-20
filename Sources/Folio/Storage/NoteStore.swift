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
    /// Note templates (kept in the library's hidden `.folio/templates`).
    case templates
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
    /// The note of the active tab in the main window.
    @Published var selectedNoteID: UUID? {
        didSet { if oldValue != selectedNoteID { openSelected(replacing: oldValue) } }
    }
    /// Open notes, shared by tabs, the split view and note windows (one document per note).
    @Published private(set) var documents: [UUID: NoteDocument] = [:]
    /// Tabs of the main window (note ids, left to right).
    @Published private(set) var tabs: [UUID] = []
    /// Note shown on the right of the split view.
    @Published var splitNoteID: UUID? {
        didSet {
            if let id = splitNoteID { ensureLoaded(id) }
            releaseUnused()
        }
    }
    /// Notes open in their own windows.
    @Published private(set) var windowNoteIDs: [UUID] = []
    /// The note whose editor had focus last (menus and shortcuts act on it).
    @Published var focusedNoteID: UUID?
    /// Notes that could not be opened, with their diagnosis.
    @Published private(set) var failures: [UUID: DamagedNote] = [:]
    /// The next selection opens a new tab instead of replacing the active one.
    private var nextSelectionInNewTab = false

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
    @Published private(set) var recent: RecentList = {
        if let d = UserDefaults.standard.data(forKey: "folio.recent"), let r = try? JSONDecoder().decode(RecentList.self, from: d) { return r }
        return RecentList()
    }() {
        didSet { if let d = try? JSONEncoder().encode(recent) { UserDefaults.standard.set(d, forKey: "folio.recent") } }
    }
    /// Note templates.
    @Published private(set) var templates: [NoteRef] = []
    /// Block kinds of notes saved before 0.15 (read once, when a type filter needs them).
    private var kindsCache: [URL: [String]] = [:]
    @Published var lastError: String?
    /// Items in Folio's trash.
    @Published private(set) var trashItems: [TrashItem] = []
    /// Note files in the library that cannot be read at all.
    @Published private(set) var damagedNotes: [DamagedNote] = []
    /// The selected note could not be opened; the editor shows the diagnosis instead.
    var openFailure: DamagedNote? { selectedNoteID.flatMap { failures[$0] } }
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
        for doc in documents.values { doc.saveNow() }
        tabs = []
        splitNoteID = nil
        selectedNoteID = nil
        closeAllDocuments()
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
            list = list.filter { ref in
                search.matches(ref.meta, folderPath: relativeFolderName(ref.folderURL),
                               kinds: search.types.isEmpty || ref.meta.kinds != nil ? nil : kinds(of: ref))
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

    private func kinds(of ref: NoteRef) -> [String] {
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

    private func openSelected(replacing old: UUID?) {
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

    private func closeAllDocuments() {
        for (id, doc) in documents { doc.saveNow(); KernelManager.shared.shutdown(note: id) }
        documents = [:]
        failures = [:]
    }

    /// Closes a note everywhere (it was deleted or moved away).
    private func closeDocument(_ id: UUID) {
        if let doc = documents[id] { doc.saveNow(); KernelManager.shared.shutdown(note: id) }
        documents[id] = nil
        tabs.removeAll { $0 == id }
        if splitNoteID == id { splitNoteID = nil }
        windowNoteIDs.removeAll { $0 == id }
    }

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
    private func open(_ url: URL, id: UUID) {
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

    // MARK: Tags

    struct TagEditProgress: Equatable {
        var done = 0
        var total = 0
        var changed = 0
        var failures: [String] = []
        var finished = false
    }

    @Published var tagEdit: TagEditProgress?

    /// Renames (or merges, when `newTag` already exists) or removes (`newTag` nil) a tag in every note
    /// that has it. Each changed note gets a version first; failures are listed, the rest continues.
    func editTag(_ tag: String, to newTag: String?) async {
        for doc in documents.values { doc.saveNow() }
        let affected = notes.filter { ref in ref.meta.tags.contains { $0 == tag || $0.hasPrefix(tag + "/") } }
        tagEdit = TagEditProgress(total: affected.count)
        let reopen = affected.map(\.id).filter { documents[$0] != nil }
        for ref in affected {
            do {
                let data = try Data(contentsOf: ref.url)
                var file = try NoteFile.decode(data)
                var changed = false
                for i in file.body.blocks.indices where file.body.blocks[i].kind == .text {
                    guard let rtf = file.body.blocks[i].rtf else { continue }
                    let s = RichTextCodec.attributedString(from: rtf)
                    let edits = TagEdit.edits(in: s.string, tag: tag, to: newTag)
                    guard !edits.isEmpty else { continue }
                    for e in edits.reversed() { s.replaceCharacters(in: e.range, with: e.replacement) }
                    file.body.blocks[i].rtf = RichTextCodec.rtfData(from: s)
                    changed = true
                }
                if changed {
                    try? history.record(data, noteID: file.meta.id, force: true)
                    let doc = NoteDocument(file: file, url: ref.url)
                    let updated = doc.makeFile()
                    try updated.write(to: ref.url)
                    if let i = notes.firstIndex(where: { $0.id == ref.id }) { notes[i].meta = updated.meta }
                    tagEdit?.changed += 1
                }
            } catch {
                tagEdit?.failures.append("\(ref.meta.title.isEmpty ? ref.url.lastPathComponent : ref.meta.title): \(error.localizedDescription)")
            }
            tagEdit?.done += 1
            await Task.yield()
        }
        tagEdit?.finished = true
        if case .tag(let t) = sidebarSelection, t == tag { sidebarSelection = newTag.map { .tag($0) } ?? .all }
        for id in reopen { reloadDocument(id) }
    }

    // MARK: Templates

    var templatesFolder: URL { LibraryData.folder(rootURL, "templates") }

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

    private func writeTemplate(_ file: NoteFile) -> URL? {
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

    // MARK: External changes

    /// Called every few seconds and when Folio becomes active.
    func checkExternalChange() {
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
            reloadDocument(doc.id)
        case .keepBoth:
            let stamp = Date().formatted(date: .numeric, time: .shortened).replacingOccurrences(of: ":", with: ".")
            saveAsNewNote(mine, in: doc.url.deletingLastPathComponent(), suffix: "(Konflikt \(stamp))")
            reloadDocument(doc.id)
        }
        if documents[doc.id] == nil, conflict.diskData == nil { reload() }
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
        if let id = damaged.report.meta?.id { failures[id] = nil }
        failures = failures.filter { $0.value.url != damaged.url }
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
        failures[id] = nil
        reload()
        ensureLoaded(id)
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

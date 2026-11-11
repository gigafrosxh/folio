import AppKit
import FolioCore

/// Sorting, manual order, favorites and smart views (#13, #14, #15). Everything lives in the library's
/// `.folio/organization.json`; note files are not changed, so ordering never touches a note's date.
extension NoteStore {
    // MARK: Loading and saving

    func loadOrganization() {
        organizationOnDisk = try? Data(contentsOf: LibraryOrganization.file(in: rootURL))
        let loaded: LibraryOrganization
        switch LibraryOrganization.load(from: rootURL) {
        case .loaded(let org): loaded = org
        case .missing: loaded = LibraryOrganization()
        case .unreadable(let kept):
            loaded = LibraryOrganization()
            lastError = "Reihenfolge, Favoriten und intelligente Ansichten dieser Bibliothek konnten nicht gelesen werden. "
                + "Folio beginnt damit neu; deine Notizen sind nicht betroffen."
                + (kept.map { " Die alte Datei liegt als „\($0)“ im Ordner .folio der Bibliothek." } ?? "")
        }
        loadingOrganization = true
        organization = loaded
        loadingOrganization = false
    }

    func saveOrganization() {
        guard !loadingOrganization else { return }
        // Someone else (sync, a restore) changed the file since Folio last saw it: keep what they added (#175).
        if let theirs = organizationChangedByOthers() {
            loadingOrganization = true
            organization = organization.merging(theirs)
            loadingOrganization = false
        }
        do {
            organizationOnDisk = try organization.saved(to: rootURL)
        } catch {
            lastError = "Reihenfolge und Favoriten konnten nicht gesichert werden: \(error.localizedDescription)"
        }
    }

    /// The organization on disk when it is not what Folio last read or wrote, and readable. A missing or
    /// unreadable file is not a change to take over.
    private func organizationChangedByOthers() -> LibraryOrganization? {
        guard let data = try? Data(contentsOf: LibraryOrganization.file(in: rootURL)), data != organizationOnDisk else { return nil }
        return try? JSONDecoder().decode(LibraryOrganization.self, from: data)
    }

    /// Called every two seconds with the other checks for outside changes: takes over a changed organization file,
    /// so favorites, views and orders from another Mac show up without a restart (#175).
    func checkOrganizationChange() {
        guard let theirs = organizationChangedByOthers() else { return }
        organizationOnDisk = try? Data(contentsOf: LibraryOrganization.file(in: rootURL))
        loadingOrganization = true
        organization = theirs
        loadingOrganization = false
        if case .smartView(let id) = sidebarSelection, smartView(id) == nil { sidebarSelection = .all }
    }

    // MARK: Sorting

    /// Where the manual order of the current list is kept; favorites keep theirs in the favorites list itself.
    func orderKey(for selection: SidebarItem?) -> String? {
        switch selection ?? .all {
        case .all: return "all"
        case .pinned: return "pinned"
        case .folder(let url): return "folder:" + relativeFolderName(url)
        case .tag(let t): return "tag:" + t
        case .smartView(let id): return "view:" + id.uuidString
        case .favorites, .trash, .damaged, .templates, .graph: return nil
        }
    }

    /// Favorites are always in their own order; elsewhere pinned notes come first, then the chosen order.
    func sorted(_ list: [NoteRef]) -> [NoteRef] {
        if sidebarSelection == .favorites {
            return ManualOrder.apply(list, order: organization.favorites, key: \.id, newFirst: false)
        }
        let ordered: [NoteRef]
        switch organization.sortMode {
        case .modified: ordered = list.sorted { $0.meta.modified > $1.meta.modified }
        case .created: ordered = list.sorted { $0.meta.created > $1.meta.created }
        case .title: ordered = list.sorted { Self.titleOrder($0, $1) }
        case .manual:
            let byDate = list.sorted { $0.meta.modified > $1.meta.modified }
            ordered = ManualOrder.apply(byDate, order: orderKey(for: sidebarSelection).flatMap { organization.noteOrder[$0] } ?? [],
                                        key: \.id, newFirst: true)
        }
        return ordered.filter(\.meta.pinned) + ordered.filter { !$0.meta.pinned }
    }

    private static func titleOrder(_ a: NoteRef, _ b: NoteRef) -> Bool {
        let r = (a.meta.title.isEmpty ? "Neue Notiz" : a.meta.title).localizedStandardCompare(b.meta.title.isEmpty ? "Neue Notiz" : b.meta.title)
        return r == .orderedSame ? a.meta.modified > b.meta.modified : r == .orderedAscending
    }

    var canReorderNotes: Bool {
        sidebarSelection == .favorites || orderKey(for: sidebarSelection) != nil
    }

    /// Moves a note in front of `target` (nil = to the end) in the list as it is shown. Outside the favorites
    /// this switches to the manual order, starting from the order the list had.
    func moveNote(_ id: UUID, before target: UUID?) {
        reorderNotes { ManualOrder.moving(id, before: target, in: $0) }
    }

    /// Moves a note one place up (-1) or down (+1).
    func stepNote(_ id: UUID, by delta: Int) {
        reorderNotes { ManualOrder.stepping(id, by: delta, in: $0) }
    }

    private func reorderNotes(_ change: ([UUID]) -> [UUID]) {
        // The whole list of this place in its current order; a search only shows part of it, and only that part
        // changes places (#170). Notes a search found elsewhere do not belong to this list's order.
        let full = sorted(selectionNotes()).map(\.id)
        let order = ManualOrder.merging(change(filteredNotes.map(\.id)), into: full)
        if sidebarSelection == .favorites {
            let hidden = organization.favorites.filter { !full.contains($0) }
            organization.favorites = order + hidden
            return
        }
        guard let key = orderKey(for: sidebarSelection) else { return }
        var org = organization
        org.noteOrder[key] = order
        org.sortMode = .manual
        organization = org
    }

    // MARK: Folders

    /// Folders in their manual order; folders without a place yet follow alphabetically.
    func orderedFolders(_ nodes: [FolderNode], parent: String) -> [FolderNode] {
        let alphabetical = nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return ManualOrder.apply(alphabetical, order: organization.folderOrder[parent] ?? [], key: \.name, newFirst: false).map { node in
            var n = node
            if let children = n.children { n.children = orderedFolders(children, parent: relativeFolderName(n.url)) }
            return n
        }
    }

    /// The folders next to `url` (same parent), in the order shown.
    func siblingFolders(of url: URL) -> (parent: String, names: [String]) {
        let parentURL = url.deletingLastPathComponent()
        let parent = parentURL.standardizedFileURL.path == rootURL.standardizedFileURL.path ? "" : relativeFolderName(parentURL)
        func find(_ nodes: [FolderNode]) -> [FolderNode]? {
            if nodes.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { return nodes }
            for n in nodes { if let found = find(n.children ?? []) { return found } }
            return nil
        }
        return (parent, (find(folders) ?? []).map(\.name))
    }

    /// Moves a folder in front of another one below the same parent; folders elsewhere are not moved (false).
    @discardableResult
    func moveFolder(_ url: URL, before target: URL) -> Bool {
        guard url.deletingLastPathComponent().standardizedFileURL == target.deletingLastPathComponent().standardizedFileURL else { return false }
        let (parent, names) = siblingFolders(of: url)
        organization.folderOrder[parent] = ManualOrder.moving(url.lastPathComponent, before: target.lastPathComponent, in: names)
        return true
    }

    func stepFolder(_ url: URL, by delta: Int) {
        let (parent, names) = siblingFolders(of: url)
        organization.folderOrder[parent] = ManualOrder.stepping(url.lastPathComponent, by: delta, in: names)
    }

    /// Back to alphabetical order for the folders next to `url`.
    func sortFoldersAlphabetically(besides url: URL) {
        organization.folderOrder[siblingFolders(of: url).parent] = nil
    }

    /// Keeps a renamed folder's place, its subfolders' order and the lists and views that refer to it.
    /// Both paths are relative to the library.
    func organizationRenamedFolder(from oldRel: String, to newRel: String) {
        guard oldRel != newRel else { return }
        let oldName = (oldRel as NSString).lastPathComponent, newName = (newRel as NSString).lastPathComponent
        func renamed(_ path: String) -> String? {
            if path == oldRel { return newRel }
            if path.hasPrefix(oldRel + "/") { return newRel + path.dropFirst(oldRel.count) }
            return nil
        }
        var org = organization
        let parentRel = (oldRel as NSString).deletingLastPathComponent
        if var names = org.folderOrder[parentRel], let i = names.firstIndex(of: oldName) {
            names[i] = newName
            org.folderOrder[parentRel] = names
        }
        org.folderOrder = Dictionary(org.folderOrder.map { (renamed($0.key) ?? $0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        org.noteOrder = Dictionary(org.noteOrder.map { key, value in
            guard key.hasPrefix("folder:"), let r = renamed(String(key.dropFirst(7))) else { return (key, value) }
            return ("folder:" + r, value)
        }, uniquingKeysWith: { a, _ in a })
        for i in org.smartViews.indices {
            if let f = org.smartViews[i].filter.folder, let r = renamed(f) { org.smartViews[i].filter.folder = r }
        }
        organization = org
    }

    // MARK: Favorites (#15)

    func isFavorite(_ id: UUID) -> Bool { organization.isFavorite(id) }

    func toggleFavorite(_ id: UUID) { organization.toggleFavorite(id) }

    var favoriteCount: Int {
        let ids = Set(notes.map(\.id))
        return organization.favorites.filter(ids.contains).count
    }

    // MARK: Smart views (#14)

    /// Notes matching a search, as the search field finds them.
    func notesMatching(_ search: SearchFilter, in list: [NoteRef]) -> [NoteRef] {
        let root = rootURL.standardizedFileURL.path
        return list.filter { ref in
            let folder = ref.folderURL.standardizedFileURL.path
            let rel = folder.hasPrefix(root) ? String(folder.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : ref.folderURL.lastPathComponent
            return search.matches(ref.meta, folderPath: rel,
                                  kinds: search.types.isEmpty || ref.meta.kinds != nil ? nil : kinds(of: ref),
                                  haystack: ref.haystack)
        }
    }

    func smartView(_ id: UUID) -> SmartView? { organization.smartViews.first { $0.id == id } }

    func smartViewNotes(_ id: UUID, in list: [NoteRef]) -> [NoteRef] {
        guard let view = smartView(id) else { return [] }
        return notesMatching(view.filter, in: list)
    }

    func smartViewCount(_ id: UUID) -> Int { smartViewNotes(id, in: notes).count }

    /// Saves the current search (typed text and filter menu) as a smart view and shows it.
    @discardableResult
    func saveSearchAsSmartView(named name: String) -> SmartView? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isSearching else { return nil }
        let view = SmartView(name: trimmed, filter: searchWithItsPlace())
        organization.smartViews.append(view)
        searchText = ""
        searchFilter = SearchFilter()
        sidebarSelection = .smartView(view.id)
        return view
    }

    /// The search as the list shows it: without „search everywhere“ it only covers the selected folder or tag, so a
    /// saved view has to remember that place too (#172).
    func searchWithItsPlace() -> SearchFilter {
        var filter = activeSearch
        guard !searchEverywhere else { return filter }
        switch sidebarSelection ?? .all {
        case .folder(let url): if filter.folder == nil { filter.folder = relativeFolderName(url) }
        case .tag(let tag): filter.tags.insert(tag.lowercased())
        default: break
        }
        return filter
    }

    func renameSmartView(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = organization.smartViews.firstIndex(where: { $0.id == id }) else { return }
        organization.smartViews[i].name = trimmed
    }

    /// Puts the view's search into the search field and filter menu, to change it and save it again.
    func editSmartView(_ id: UUID) {
        guard let view = smartView(id) else { return }
        var filters = view.filter
        filters.text = ""
        searchText = view.filter.text
        searchFilter = filters
        sidebarSelection = .all
    }

    /// Replaces the view's search with the current one.
    func updateSmartView(_ id: UUID) {
        guard isSearching, let i = organization.smartViews.firstIndex(where: { $0.id == id }) else { return }
        organization.smartViews[i].filter = searchWithItsPlace()
        searchText = ""
        searchFilter = SearchFilter()
        sidebarSelection = .smartView(id)
    }

    func deleteSmartView(_ id: UUID) {
        var org = organization
        org.smartViews.removeAll { $0.id == id }
        org.noteOrder["view:" + id.uuidString] = nil
        organization = org
        if sidebarSelection == .smartView(id) { sidebarSelection = .all }
    }

    func stepSmartView(_ id: UUID, by delta: Int) {
        let ids = ManualOrder.stepping(id, by: delta, in: organization.smartViews.map(\.id))
        organization.smartViews = ManualOrder.apply(organization.smartViews, order: ids, key: \.id, newFirst: false)
    }
}

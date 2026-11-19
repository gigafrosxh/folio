#if os(iOS)
import Foundation
import SwiftUI
import FolioCore

/// The note library on iPad and iPhone (#214, #213): `Documents/Folio` (visible in the Files app), a folder the user
/// picked (e.g. the Mac library in iCloud Drive, kept as a security-scoped bookmark), or `FOLIO_LIBRARY` for tests.
///
/// Safety as on the Mac: before a note is overwritten its previous state goes to `.folio/history`; a note changed on
/// disk since it was opened (e.g. by the Mac through a shared folder) is never overwritten but saved as a copy;
/// deleting moves to `.folio/trash`.
@MainActor
final class PadLibrary: ObservableObject {
    struct Entry: Identifiable, Hashable {
        var url: URL
        var meta: NoteMetadata
        var id: URL { url }
    }

    private(set) var root: URL
    /// The folder came from the document picker; access has to be started and stopped.
    private var scoped = false
    private static let bookmarkKey = "libraryBookmark"
    var isCustomLibrary: Bool { scoped }
    @Published private(set) var folders: [LibraryScanner.Folder] = []
    @Published private(set) var notes: [Entry] = []
    @Published private(set) var unreadable = 0
    @Published var selectedFolder: URL?
    @Published var selectedNote: URL? { didSet { if oldValue != selectedNote && !reverting { switchNote(from: oldValue) } } }
    @Published private(set) var document: PadDocument?
    @Published var message: String?
    @Published var focusSearch = false

    enum SaveResult: Equatable { case saved, failed, copied(URL) }

    private let scanner = LibraryScanner()
    /// Set while the selection is put back without opening anything.
    private var reverting = false
    private var saveTask: Task<Void, Never>?

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else if let env = ProcessInfo.processInfo.environment["FOLIO_LIBRARY"] {
            self.root = URL(fileURLWithPath: env, isDirectory: true)
        } else if let picked = Self.restoredBookmark() {
            self.root = picked
            scoped = picked.startAccessingSecurityScopedResource()
        } else {
            self.root = Self.defaultRoot
        }
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        reload()
        if notes.isEmpty { createWelcomeNote() }
    }

    static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Folio", isDirectory: true)
    }

    private static func restoredBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
    }

    /// Uses another folder as the library, e.g. the Mac's library in iCloud Drive or a shared folder (#213).
    /// The open note is saved first; nothing in either folder is moved or changed.
    func useLibrary(_ url: URL?) {
        guard saveNow() == .saved else { return }
        if scoped { root.stopAccessingSecurityScopedResource() }
        scoped = false
        if let url {
            scoped = url.startAccessingSecurityScopedResource()
            if let data = try? url.bookmarkData() { UserDefaults.standard.set(data, forKey: Self.bookmarkKey) }
            root = url
        } else {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            root = Self.defaultRoot
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        scanner.clearCache()
        setSelection(nil)
        document = nil
        selectedFolder = nil
        reload()
    }

    /// Picks up changes made elsewhere (the Mac through a shared folder): the list, and the open note when it has no
    /// unsaved edits here. With unsaved edits the next save notices the change and keeps both versions (#213).
    func refreshFromDisk() {
        reload()
        guard let doc = document, !doc.isDirty, doc.changedOnDisk else { return }
        if FileManager.default.fileExists(atPath: doc.url.path) {
            open(doc.url)
        } else {
            message = "„\(doc.file.meta.title)“ wurde anderswo gelöscht oder verschoben."
            setSelection(nil)
            document = nil
        }
    }

    func reload() {
        let result = scanner.scan(root)
        folders = result.folders
        unreadable = result.unreadable.count
        notes = result.notes.map { Entry(url: $0.url, meta: $0.meta) }
            .sorted { ($0.meta.pinned ? 1 : 0, $0.meta.modified) > ($1.meta.pinned ? 1 : 0, $1.meta.modified) }
    }

    /// Notes in the chosen folder (with subfolders), filtered by the search text (title, tags, full text).
    func visibleNotes(search: String) -> [Entry] {
        let folder = selectedFolder == root ? nil : selectedFolder?.standardizedFileURL.path
        let terms = search.lowercased().split(separator: " ").map(String.init)
        return notes.filter { e in
            if let folder, !e.url.standardizedFileURL.path.hasPrefix(folder + "/") { return false }
            let haystack = (e.meta.title + " " + e.meta.tags.joined(separator: " ") + " " + e.meta.searchText).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    // MARK: Open, edit, save

    /// Opening another note first saves the open one. If that fails, the selection goes back and the unsaved edits
    /// stay open; nothing is replaced (#260).
    private func switchNote(from old: URL?) {
        if saveNow(selectCopy: false) == .failed {
            setSelection(old)
            return
        }
        open(selectedNote)
    }

    private func setSelection(_ url: URL?) {
        reverting = true
        selectedNote = url
        reverting = false
    }

    private func open(_ url: URL?) {
        guard let url else { document = nil; return }
        do {
            document = try PadDocument(url: url)
        } catch {
            document = nil
            message = "„\(url.lastPathComponent)“ lässt sich nicht öffnen: \(error.localizedDescription)"
        }
    }

    /// Called on every edit; saves a moment after typing pauses.
    func changed() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.autosave()
        }
    }

    private func autosave() async {
        guard let doc = document else { return }
        do {
            let outcome = try await doc.saveInBackground(history: NoteHistory(library: root))
            handle(outcome, of: doc, selectCopy: document === doc)
        } catch {
            message = "Sichern fehlgeschlagen: \(error.localizedDescription) Die Änderungen bleiben offen."
        }
    }

    /// Saves the open note. A note changed elsewhere is kept and the edits go to a copy; with `selectCopy` (a plain
    /// save, not a switch to another note) the copy is opened, so selection and editor always show the same note.
    @discardableResult
    func saveNow(selectCopy: Bool = true) -> SaveResult {
        saveTask?.cancel()
        guard let doc = document, doc.isDirty else { return .saved }
        do {
            return handle(try doc.save(history: NoteHistory(library: root)), of: doc, selectCopy: selectCopy)
        } catch {
            message = "Sichern fehlgeschlagen: \(error.localizedDescription) Die Änderungen bleiben offen."
            return .failed
        }
    }

    @discardableResult
    private func handle(_ outcome: PadDocument.SaveOutcome, of doc: PadDocument, selectCopy: Bool) -> SaveResult {
        if case .savedAsCopy(let copy) = outcome {
            message = "Die Notiz wurde inzwischen anderswo geändert. Deine Fassung liegt als „\(copy.deletingPathExtension().lastPathComponent)“ daneben."
            reload()
            if selectCopy {
                setSelection(copy)
                open(copy)
            }
            return .copied(copy)
        }
        if let i = notes.firstIndex(where: { $0.url == doc.url }) { notes[i].meta = doc.file.meta }
        return .saved
    }

    // MARK: Create, delete

    func createNote(text: String = "") {
        saveNow()
        let folder = selectedFolder ?? root
        var file = NoteFile(meta: NoteMetadata(title: "Neue Notiz"), body: NoteBody(blocks: [PadDocument.textRecord(text)]))
        PadDocument.refreshMeta(&file)
        let url = PadDocument.freeURL(in: folder, title: "Neue Notiz")
        do {
            try file.write(to: url)
            reload()
            selectedNote = url
        } catch {
            message = "Neue Notiz nicht möglich: \(error.localizedDescription)"
        }
    }

    func trashSelected() {
        guard let url = selectedNote else { return }
        // Not after a failed save or a conflict copy: the user should see first what is where.
        guard saveNow() == .saved, selectedNote == url else { return }
        do {
            _ = try LibraryTrash(library: root).moveToTrash(url, title: document?.file.meta.title)
            document = nil
            selectedNote = nil
            reload()
        } catch {
            message = "Löschen fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func createWelcomeNote() {
        createNote(text: "Willkommen in Folio auf dem iPad\nDiese Bibliothek liegt in der Dateien-App unter „Auf meinem iPad › Folio“. Notizen vom Mac (.folio) lassen sich dort hineinlegen und hier bearbeiten.")
    }
}
#endif

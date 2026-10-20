import AppKit
import Combine
import FolioCore

struct NoteRef: Identifiable, Hashable {
    var meta: NoteMetadata { didSet { haystack = SearchFilter.haystack(for: meta) } }
    var url: URL
    /// Title and text lowercased once, so typing in the search field stays fast in big libraries (#62).
    private(set) var haystack: String
    var id: UUID { meta.id }
    var folderURL: URL { url.deletingLastPathComponent() }

    init(meta: NoteMetadata, url: URL) {
        self.meta = meta
        self.url = url
        haystack = SearchFilter.haystack(for: meta)
    }

    static func == (a: NoteRef, b: NoteRef) -> Bool { a.meta == b.meta && a.url == b.url }
    func hash(into h: inout Hasher) { h.combine(meta.id); h.combine(url) }
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

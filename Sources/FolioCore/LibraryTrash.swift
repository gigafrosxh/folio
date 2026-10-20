import Foundation

/// Something deleted in Folio: a note file or a folder with notes.
public struct TrashItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Path below the library root where it was, e.g. "Notizen/Einkauf.folio".
    public var originalPath: String
    public var deletedAt: Date
    public var isFolder: Bool
    public var title: String
    /// Notes inside (1 for a note).
    public var noteCount: Int
    /// Note ids inside, so their version history can be removed when the item is deleted for good.
    public var noteIDs: [UUID]

    public var name: String { (originalPath as NSString).lastPathComponent }
}

/// Folio's own trash inside the library (`.folio/trash/<id>/`): deleted notes and folders stay
/// restorable to their old place until they are deleted for good or expire.
public struct LibraryTrash: Sendable {
    public let library: URL
    public let directory: URL

    public enum TrashError: LocalizedError {
        case missing(String)
        case outsideLibrary
        public var errorDescription: String? {
            switch self {
            case .missing(let name): return "„\(name)“ ist nicht mehr im Papierkorb."
            case .outsideLibrary: return "Nur Notizen und Ordner der Bibliothek können in den Papierkorb."
            }
        }
    }

    public init(library: URL) {
        self.library = library.standardizedFileURL
        directory = LibraryData.folder(library, "trash")
    }

    private func info(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathComponent("info.json") }

    /// Where the trashed file or folder itself lies.
    public func contentURL(of item: TrashItem) -> URL {
        directory.appendingPathComponent(item.id.uuidString).appendingPathComponent(item.name)
    }

    /// Moves a note file or a folder from the library into the trash.
    @discardableResult
    public func moveToTrash(_ url: URL, title: String? = nil, date: Date = Date()) throws -> TrashItem {
        let fm = FileManager.default
        let source = url.standardizedFileURL
        let root = library.path.hasSuffix("/") ? library.path : library.path + "/"
        guard source.path.hasPrefix(root) else { throw TrashError.outsideLibrary }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { throw TrashError.missing(source.lastPathComponent) }
        let notes = isDir.boolValue ? Self.noteFiles(in: source) : [source]
        let ids = notes.compactMap { try? NoteFile.readMetadata(at: $0).id }
        let item = TrashItem(id: UUID(), originalPath: String(source.path.dropFirst(root.count)), deletedAt: date,
                             isFolder: isDir.boolValue,
                             title: title ?? source.deletingPathExtension().lastPathComponent,
                             noteCount: notes.count, noteIDs: ids)
        let holder = directory.appendingPathComponent(item.id.uuidString, isDirectory: true)
        try fm.createDirectory(at: holder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(item).write(to: info(item.id), options: .atomic)
        do {
            try fm.moveItem(at: source, to: contentURL(of: item))
        } catch {
            try? fm.removeItem(at: holder)
            throw error
        }
        return item
    }

    /// Everything in the trash, most recently deleted first.
    public func items() -> [TrashItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dirs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("info.json")),
                  let item = try? decoder.decode(TrashItem.self, from: data),
                  FileManager.default.fileExists(atPath: contentURL(of: item).path) else { return nil }
            return item
        }.sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Puts an item back where it was (recreating missing folders; a new name if the place is taken).
    @discardableResult
    public func restore(_ item: TrashItem) throws -> URL {
        let fm = FileManager.default
        let content = contentURL(of: item)
        guard fm.fileExists(atPath: content.path) else { throw TrashError.missing(item.title) }
        let original = library.appendingPathComponent(item.originalPath)
        let parent = original.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = Self.uniqueURL(original)
        try fm.moveItem(at: content, to: target)
        try? fm.removeItem(at: directory.appendingPathComponent(item.id.uuidString))
        return target
    }

    /// Deletes an item for good. `history` also loses the versions of its notes.
    public func deletePermanently(_ item: TrashItem, history: NoteHistory? = nil) throws {
        let holder = directory.appendingPathComponent(item.id.uuidString)
        guard FileManager.default.fileExists(atPath: holder.path) else { throw TrashError.missing(item.title) }
        try FileManager.default.removeItem(at: holder)
        for id in item.noteIDs { history?.removeAll(noteID: id) }
    }

    /// Deletes items older than `days` days; returns how many.
    @discardableResult
    public func purge(olderThan days: Int, now: Date = Date(), history: NoteHistory? = nil) -> Int {
        guard days > 0 else { return 0 }
        let limit = now.addingTimeInterval(-Double(days) * 86_400)
        var count = 0
        for item in items() where item.deletedAt < limit {
            if (try? deletePermanently(item, history: history)) != nil { count += 1 }
        }
        return count
    }

    @discardableResult
    public func empty(history: NoteHistory? = nil) -> Int {
        var count = 0
        for item in items() where (try? deletePermanently(item, history: history)) != nil { count += 1 }
        return count
    }

    static func noteFiles(in folder: URL) -> [URL] {
        let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var out: [URL] = []
        while let url = e?.nextObject() as? URL {
            if url.pathExtension == FolioArchive.fileExtension { out.append(url) }
        }
        return out
    }

    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}

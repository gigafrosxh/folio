import Foundation

/// Hidden folder inside the library for Folio's own data (versions, trash, quarantined files).
/// It starts with a dot, so the library scan, Finder and the note list skip it.
public enum LibraryData {
    public static let folderName = ".folio"

    public static func folder(_ library: URL, _ name: String) -> URL {
        library.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }
}

/// A saved earlier state of a note.
public struct NoteVersion: Identifiable, Hashable, Sendable {
    public var url: URL
    public var date: Date
    public var size: Int64
    public var id: URL { url }
}

/// Automatic version history: copies of a note's file in `<library>/.folio/history/<note id>/`.
///
/// A copy is written at most every few minutes while editing, always before something replaces the
/// note (restoring a version, resolving a conflict, moving it to the trash), and never twice for the
/// same content. Old copies are thinned out with `RetentionPolicy.versions`.
public struct NoteHistory: Sendable {
    public let directory: URL
    public var policy: RetentionPolicy
    /// Minimum time between two automatic copies while editing.
    public var interval: TimeInterval

    public init(library: URL, policy: RetentionPolicy = .versions, interval: TimeInterval = 300) {
        directory = LibraryData.folder(library, "history")
        self.policy = policy
        self.interval = interval
    }

    func folder(for noteID: UUID) -> URL { directory.appendingPathComponent(noteID.uuidString, isDirectory: true) }

    /// Versions of a note, newest first.
    public func versions(of noteID: UUID) -> [NoteVersion] {
        let dir = folder(for: noteID)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return items.compactMap { url -> NoteVersion? in
            guard url.pathExtension == FolioArchive.fileExtension, let date = Stamp.date(url.lastPathComponent) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return NoteVersion(url: url, date: date, size: size)
        }.sorted { $0.date > $1.date }
    }

    /// Stores `data` (an encoded note) as a new version, unless the newest version is younger than
    /// `interval` (ignored with `force`) or has the same content. Returns the new version, if any.
    @discardableResult
    public func record(_ data: Data, noteID: UUID, date: Date = Date(), force: Bool = false) throws -> NoteVersion? {
        let existing = versions(of: noteID)
        if let latest = existing.first {
            if !force, date.timeIntervalSince(latest.date) < interval { return nil }
            if let old = try? Data(contentsOf: latest.url), Self.sameContent(old, data) { return nil }
        }
        let dir = folder(for: noteID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Stamp.string(date)).appendingPathExtension(FolioArchive.fileExtension)
        try data.write(to: url, options: .atomic)
        prune(noteID: noteID, now: date)
        return NoteVersion(url: url, date: date, size: Int64(data.count))
    }

    /// Two encoded notes have the same content when body and attachments match (the metadata always
    /// differs because of the modification date).
    static func sameContent(_ a: Data, _ b: Data) -> Bool {
        guard let x = try? FolioArchive.decode(a), let y = try? FolioArchive.decode(b) else { return false }
        return x.body == y.body && x.attachments.map(\.data) == y.attachments.map(\.data)
    }

    public func read(_ version: NoteVersion) throws -> NoteFile { try NoteFile.read(from: version.url) }

    @discardableResult
    public func prune(noteID: UUID, now: Date = Date()) -> Int {
        let all = versions(of: noteID)
        let doomed = Set(policy.toDelete(all.map(\.date), now: now))
        var removed = 0
        for v in all where doomed.contains(v.date) {
            if (try? FileManager.default.removeItem(at: v.url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Deletes all versions of a note (when the note is deleted for good).
    public func removeAll(noteID: UUID) {
        try? FileManager.default.removeItem(at: folder(for: noteID))
    }
}

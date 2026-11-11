import Foundation

/// Two note files with the same id: a copy made in the Finder, a sync service's conflict copy or a file
/// restored from a backup. Folio keeps one file under the id and gives every other one a new identity, so
/// each file shows up as its own note (#166).
public enum NoteIdentity {
    public struct Resolution: Equatable, Sendable {
        /// Files that keep their id.
        public var keep: [URL]
        /// Files that get a new identity.
        public var renew: [URL]
    }

    /// `known` is where each id was found before (the file the open editor and the history belong to). Without
    /// one, the oldest file keeps the id; the path decides when the dates are equal.
    public static func resolve(_ notes: [(url: URL, id: UUID)], known: [UUID: URL] = [:], created: (URL) -> Date = creationDate) -> Resolution {
        var resolution = Resolution(keep: [], renew: [])
        for group in Dictionary(grouping: notes, by: \.id).values {
            let urls = group.map(\.url)
            let keeper = keeper(of: urls, known: known[group[0].id], created: created)
            resolution.keep.append(keeper)
            resolution.renew += urls.filter { $0 != keeper }
        }
        resolution.keep.sort { $0.path < $1.path }
        resolution.renew.sort { $0.path < $1.path }
        return resolution
    }

    private static func keeper(of urls: [URL], known: URL?, created: (URL) -> Date) -> URL {
        if let known, let match = urls.first(where: { $0.standardizedFileURL == known.standardizedFileURL }) { return match }
        return urls.min { a, b in
            let (da, db) = (created(a), created(b))
            return da != db ? da < db : a.path < b.path
        }!
    }

    public static func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
    }

    /// The same note with new ids for itself, its blocks and its attachments; title, text and dates stay.
    public static func renewed(_ file: NoteFile) -> NoteFile {
        var copy = file
        copy.meta.id = UUID()
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
}

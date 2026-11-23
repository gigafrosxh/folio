import Foundation

/// Saving a note safely, the same steps on every platform (#310): an older snapshot never replaces a newer one (#267),
/// a note changed elsewhere is never overwritten but saved as a copy with new ids (#268, #271), a note deleted elsewhere
/// is not recreated (#269), and the previous state is kept as a version before the file is replaced (#260, #304).
/// Platforms add what is theirs: file coordination on iOS, conflict screens on the Mac.
public struct NoteSaveTransaction: Sendable {
    public enum Outcome: Equatable, Sendable {
        case saved
        case unchanged
        case savedAsCopy(URL)
        case deletedElsewhere(URL)
    }

    public let history: NoteHistory
    public let fs: any FileOperations
    /// Appended to the name of a conflict copy, e.g. " (iPad)".
    public let copySuffix: String

    public init(history: NoteHistory, fs: any FileOperations = LocalFileOperations(), copySuffix: String) {
        self.history = history
        self.fs = fs
        self.copySuffix = copySuffix
    }

    /// Writes `data` (the encoded `snapshot`, taken at `revision`) to `url`, which was `expected` when it was read or
    /// saved last. `revisions` records what was written; the result says whether the document is clean afterwards
    /// (no edit came in since the snapshot) and the file's new stamp.
    public func save(
        _ snapshot: NoteFile, data: Data, to url: URL, expected: FileStamp?, revision: Int, current: Int, revisions: inout SaveRevisions
    ) throws -> (outcome: Outcome, clean: Bool, stamp: FileStamp?) {
        guard revisions.mayWrite(revision) else { return (.unchanged, false, expected) }
        let exists = fs.fileExists(url)
        if !exists, expected != nil {
            let copy = try writeCopy(snapshot, next: url)
            return (.deletedElsewhere(copy), revisions.didWrite(revision, current: current), expected)
        }
        if exists, FileStamp.of(url) != expected {
            let copy = try writeCopy(snapshot, next: url)
            return (.savedAsCopy(copy), revisions.didWrite(revision, current: current), expected)
        }
        // The previous state is kept first; if that is not possible, the note is not overwritten.
        if exists { try history.recordFile(at: url, noteID: snapshot.meta.id) }
        try fs.write(data, to: url)
        return (.saved, revisions.didWrite(revision, current: current), FileStamp.of(url))
    }

    /// The edits as a new note next to `url`, with new ids for note, blocks and attachments (both may be open at once).
    private func writeCopy(_ snapshot: NoteFile, next url: URL) throws -> URL {
        let copy = Self.freeURL(in: url.deletingLastPathComponent(), title: url.deletingPathExtension().lastPathComponent + copySuffix, fs: fs)
        try fs.write(try NoteIdentity.renewed(snapshot).encoded(), to: copy)
        return copy
    }

    /// A file name in `folder` that is not taken yet: "<title>.folio", "<title> 2.folio" … The title is shortened so
    /// that the name with counter and extension stays within the 255 bytes a file name may have (#366).
    public static func freeURL(in folder: URL, title: String, fs: any FileOperations = LocalFileOperations()) -> URL {
        let base = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        func candidate(_ n: Int) -> URL {
            let counter = n == 1 ? "" : " \(n)"
            let name = fitting(base, extra: counter.utf8.count + 1 + FolioArchive.fileExtension.utf8.count) + counter
            return folder.appendingPathComponent(name).appendingPathExtension(FolioArchive.fileExtension)
        }
        var n = 1
        while fs.fileExists(candidate(n)) { n += 1 }
        return candidate(n)
    }

    /// Longest prefix of `name` (whole characters) that leaves room for `extra` bytes in a 255-byte file name.
    static func fitting(_ name: String, extra: Int) -> String {
        var out = name
        while out.utf8.count + extra > 255, !out.isEmpty { out.removeLast() }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

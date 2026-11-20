import Foundation

/// Which edit state of a document is on disk. Autosave compresses a snapshot off the main thread, so two saves can
/// finish in reverse order; an older snapshot must then never replace a newer one (#267), and finishing a save (or a
/// conflict copy) may only mark the document clean when no edit came in meanwhile (#268).
public struct SaveRevisions: Equatable, Sendable {
    /// Revision of the newest snapshot that was written (to the note or to a conflict copy).
    public private(set) var written: Int

    /// `opened` is the revision of the state read from disk.
    public init(opened: Int = 0) { written = opened }

    /// A snapshot taken at `revision` may still be written: nothing newer was written since it was taken.
    public func mayWrite(_ revision: Int) -> Bool { revision > written }

    /// Records a written snapshot; returns whether the document is clean, i.e. no edit came after the snapshot.
    @discardableResult
    public mutating func didWrite(_ revision: Int, current: Int) -> Bool {
        written = max(written, revision)
        return revision == current
    }
}

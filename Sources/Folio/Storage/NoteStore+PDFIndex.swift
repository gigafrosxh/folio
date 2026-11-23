import Foundation
import FolioCore

/// Makes the text inside PDFs of notes that are not open searchable (#43). Runs once in the background after the
/// library loads; each note is written only when its file did not change meanwhile, and keeps its date.
extension NoteStore {
    func indexPDFsInLibrary() {
        let candidates = notes.filter { $0.meta.kinds == nil || $0.meta.kinds?.contains("pdf") == true }.map { ($0.id, $0.url) }
        guard !candidates.isEmpty else { return }
        let checked = PDFIndexLedger.shared
        Task.detached(priority: .background) {
            for (id, url) in candidates {
                // Every reload used to unpack every such note again; unchanged files are skipped now (#374).
                guard let stamp = LibraryScanner.CacheKey.of(url), checked.isNew(url, stamp) else { continue }
                guard await NoteStore.shared.documents[id] == nil,
                    let data = try? Data(contentsOf: url), var file = try? NoteFile.decode(data),
                    file.indexPDFText()
                else { continue }
                let before = FileFingerprint(data: data)
                let indexed = file
                let ok: Bool = await MainActor.run {
                    let store = NoteStore.shared
                    // Opened or changed by someone in the meantime: the open note indexes itself.
                    guard store.documents[id] == nil, FileFingerprint.of(url) == before,
                        (try? indexed.write(to: url)) != nil
                    else { return false }
                    if let i = store.notes.firstIndex(where: { $0.id == id }) { store.notes[i].meta = indexed.meta }
                    return true
                }
                _ = ok
            }
        }
    }
}

/// Which note files the PDF indexer already looked at, as they were then (#374).
final class PDFIndexLedger: @unchecked Sendable {
    static let shared = PDFIndexLedger()
    private let lock = NSLock()
    private var seen: [URL: LibraryScanner.CacheKey] = [:]

    /// True the first time a file is seen in this state; later calls with the same state return false.
    func isNew(_ url: URL, _ stamp: LibraryScanner.CacheKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if seen[url] == stamp { return false }
        seen[url] = stamp
        return true
    }
}

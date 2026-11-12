import Foundation
import FolioCore

/// Makes the text inside PDFs of notes that are not open searchable (#43). Runs once in the background after the
/// library loads; each note is written only when its file did not change meanwhile, and keeps its date.
extension NoteStore {
    func indexPDFsInLibrary() {
        let candidates = notes.filter { $0.meta.kinds == nil || $0.meta.kinds?.contains("pdf") == true }.map { ($0.id, $0.url) }
        guard !candidates.isEmpty else { return }
        Task.detached(priority: .background) {
            for (id, url) in candidates {
                guard await NoteStore.shared.documents[id] == nil,
                      let data = try? Data(contentsOf: url), var file = try? NoteFile.decode(data),
                      file.indexPDFText() else { continue }
                let before = FileFingerprint(data: data)
                let indexed = file
                let ok: Bool = await MainActor.run {
                    let store = NoteStore.shared
                    // Opened or changed by someone in the meantime: the open note indexes itself.
                    guard store.documents[id] == nil, FileFingerprint.of(url) == before,
                          (try? indexed.write(to: url)) != nil else { return false }
                    if let i = store.notes.firstIndex(where: { $0.id == id }) { store.notes[i].meta = indexed.meta }
                    return true
                }
                _ = ok
            }
        }
    }
}

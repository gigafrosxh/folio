import AppKit
import Combine
import FolioCore

extension NoteStore {
    // MARK: Tags

    struct TagEditProgress: Equatable {
        var done = 0
        var total = 0
        var changed = 0
        var failures: [String] = []
        var finished = false
    }


    /// Renames (or merges, when `newTag` already exists) or removes (`newTag` nil) a tag in every note
    /// that has it. Each changed note gets a version first; failures are listed, the rest continues.
    func editTag(_ tag: String, to newTag: String?) async {
        for doc in documents.values { doc.saveNow() }
        let affected = notes.filter { ref in ref.meta.tags.contains { $0 == tag || $0.hasPrefix(tag + "/") } }
        tagEdit = TagEditProgress(total: affected.count)
        let reopen = affected.map(\.id).filter { documents[$0] != nil }
        for ref in affected {
            do {
                let data = try Data(contentsOf: ref.url)
                var file = try NoteFile.decode(data)
                var changed = false
                for i in file.body.blocks.indices where file.body.blocks[i].kind == .text {
                    guard let rtf = file.body.blocks[i].rtf else { continue }
                    let s = RichTextCodec.attributedString(from: rtf)
                    let edits = TagEdit.edits(in: s.string, tag: tag, to: newTag)
                    guard !edits.isEmpty else { continue }
                    for e in edits.reversed() { s.replaceCharacters(in: e.range, with: e.replacement) }
                    file.body.blocks[i].rtf = RichTextCodec.rtfData(from: s)
                    changed = true
                }
                if changed {
                    try? history.record(data, noteID: file.meta.id, force: true)
                    let doc = NoteDocument(file: file, url: ref.url)
                    let updated = doc.makeFile()
                    try updated.write(to: ref.url)
                    if let i = notes.firstIndex(where: { $0.id == ref.id }) { notes[i].meta = updated.meta }
                    tagEdit?.changed += 1
                }
            } catch {
                tagEdit?.failures.append("\(ref.meta.title.isEmpty ? ref.url.lastPathComponent : ref.meta.title): \(error.localizedDescription)")
            }
            tagEdit?.done += 1
            await Task.yield()
        }
        tagEdit?.finished = true
        if case .tag(let t) = sidebarSelection, t == tag { sidebarSelection = newTag.map { .tag($0) } ?? .all }
        for id in reopen { reloadDocument(id) }
    }
}

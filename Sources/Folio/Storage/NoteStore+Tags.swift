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
            applyTagEdit(to: ref, tag: tag, newTag: newTag)
            tagEdit?.done += 1
            await Task.yield()
        }
        tagEdit?.finished = true
        // The tag's own note order and saved searches follow the new name (#174).
        if let failures = tagEdit?.failures, failures.isEmpty {
            organization.renameTag(tag.lowercased(), to: newTag?.lowercased())
            if tag != tag.lowercased() { organization.renameTag(tag, to: newTag) }
        }
        if case .tag(let t) = sidebarSelection, t == tag { sidebarSelection = newTag.map { .tag($0) } ?? .all }
        for id in reopen { reloadDocument(id) }
    }

    /// One failed note is listed; the others go on.
    private func applyTagEdit(to ref: NoteRef, tag: String, newTag: String?) {
        do {
            let data = try Data(contentsOf: ref.url)
            var file = try NoteFile.decode(data)
            guard Self.renameTag(tag, to: newTag, in: &file) else { return }
            try? history.record(data, noteID: file.meta.id, force: true)
            let updated = NoteDocument(file: file, url: ref.url).makeFile()
            try updated.write(to: ref.url)
            if let i = notes.firstIndex(where: { $0.id == ref.id }) { notes[i].meta = updated.meta }
            tagEdit?.changed += 1
        } catch {
            tagEdit?.failures.append("\(ref.meta.title.isEmpty ? ref.url.lastPathComponent : ref.meta.title): \(error.localizedDescription)")
        }
    }

    /// Changes the tag in the note's text blocks and says whether anything changed. Touches no file.
    static func renameTag(_ tag: String, to newTag: String?, in file: inout NoteFile) -> Bool {
        var changed = false
        for i in file.body.blocks.indices where file.body.blocks[i].kind == .text {
            guard let rtf = file.body.blocks[i].rtf else { continue }
            let text = RichTextCodec.attributedString(from: rtf)
            let edits = TagEdit.edits(in: text.string, tag: tag, to: newTag)
            guard !edits.isEmpty else { continue }
            for edit in edits.reversed() { text.replaceCharacters(in: edit.range, with: edit.replacement) }
            file.body.blocks[i].rtf = RichTextCodec.rtfData(from: text)
            changed = true
        }
        return changed
    }
}

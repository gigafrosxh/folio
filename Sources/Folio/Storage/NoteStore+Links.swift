import AppKit
import FolioCore

/// Note links, `[[Titel]]` links and the graph (#110–#119).
extension NoteStore {
    /// Updates `linkIndex` for notes that are new, changed, renamed or gone – never a full rebuild.
    func refreshLinkIndex() {
        var seen = Set<UUID>()
        for ref in notes {
            seen.insert(ref.id)
            let folder = relativeFolderName(ref.folderURL)
            let stamp = "\(ref.meta.modified.timeIntervalSince1970)|\(ref.meta.title)|\(folder)|\(ref.meta.links.count)|\(ref.meta.tags.joined(separator: ","))"
            if linkIndexStamps[ref.id] != stamp {
                linkIndex.update(ref.meta, folder: folder)
                linkIndexStamps[ref.id] = stamp
            }
        }
        for gone in Set(linkIndexStamps.keys).subtracting(seen) {
            linkIndex.remove(gone)
            linkIndexStamps[gone] = nil
        }
    }

    /// `[[Titel]]`: opens the note with that title, or creates it next to the current note (#115).
    func openOrCreate(title: String) {
        if let id = linkIndex.resolve(title) { open(noteID: id); return }
        let folder = currentDocument?.url.deletingLastPathComponent()
        guard let ref = createNote(titled: title, in: folder) else { return }
        open(noteID: ref.id)
    }

    /// A new note whose first line (title) is `title`.
    @discardableResult
    func createNote(titled title: String, in folder: URL? = nil, body text: String = "") -> NoteRef? {
        guard let ref = createNote(in: folder), let doc = currentDocument, doc.id == ref.id else { return nil }
        let theme = ThemeManager.shared
        let s = NSMutableAttributedString(string: title, attributes: TextStyle.title.attributes(theme: theme))
        s.append(NSAttributedString(string: "\n" + text, attributes: theme.bodyAttributes))
        doc.blocks[0].storage.setAttributedString(s)
        doc.markDirty()
        doc.saveNow()
        return notes.first { $0.id == ref.id } ?? ref
    }

    /// Notes that mention the title of `id` without linking to it (#112).
    func unlinkedMentions(of id: UUID) -> [NoteRef] {
        guard let target = notes.first(where: { $0.id == id }) else { return [] }
        let ids = Set(Mentions.unlinked(to: id, title: target.meta.title, in: notes.map(\.meta), index: linkIndex))
        return notes.filter { ids.contains($0.id) }.sorted { $0.meta.modified > $1.meta.modified }
    }

    /// Turns the first unlinked mention of `target`'s title in `source` into a `[[Titel]]` link (#112).
    /// The text stays the same apart from the brackets; it goes through the note's undo and save.
    @discardableResult
    func linkMention(in source: UUID, to target: UUID) -> Bool {
        guard let title = notes.first(where: { $0.id == target })?.meta.title,
              let ref = notes.first(where: { $0.id == source }) else { return false }
        if documents[source] == nil { open(ref.url, id: source) }
        guard let doc = document(for: source) else { return false }
        for block in doc.blocks where block.kind == .text {
            guard let r = Mentions.ranges(of: title, in: block.storage.string).first else { continue }
            let found = (block.storage.string as NSString).substring(with: r)
            let attrs = block.storage.attributes(at: r.location, effectiveRange: nil)
            let replacement = found == title ? "[[\(title)]]" : "[[\(title)|\(found)]]"
            block.storage.replaceCharacters(in: r, with: NSAttributedString(string: replacement, attributes: attrs))
            block.storage.addAttribute(.link, value: WikiLink.url(for: title), range: NSRange(location: r.location, length: (replacement as NSString).length))
            doc.markDirty()
            doc.saveNow()
            return true
        }
        return false
    }
}

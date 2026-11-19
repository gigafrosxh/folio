import AppKit
import FolioCore

/// What Shortcuts and AppleScript may do with notes (#70): create, search, open and append. One place, so both use
/// the same rules: nothing is deleted or overwritten, open notes get changes through their editor (unsaved edits stay).
@MainActor
enum NoteAutomation {
    enum Failure: LocalizedError {
        case notFound(String)
        case notCreated(String)
        case empty
        case ambiguous(String, Int)

        var errorDescription: String? {
            switch self {
            case .notFound(let q): return "Keine Notiz „\(q)“ gefunden."
            case .notCreated(let why): return "Die Notiz konnte nicht angelegt werden: \(why)"
            case .empty: return "Es wurde kein Text übergeben."
            case .ambiguous(let q, let n): return "„\(q)“ passt auf mehrere Notizen (\(n == 2 ? "mindestens 2" : "\(n)")). Gib den genauen Titel oder die ID an."
            }
        }
    }

    /// A new note in the library's top folder; its title is the first line. Written straight to disk: the selection,
    /// the editor and the keyboard stay where the user is (#347).
    static func create(title: String, text: String = "") throws -> NoteRef {
        let store = NoteStore.shared
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty || !text.isEmpty else { throw Failure.empty }
        let theme = ThemeManager.shared
        let rich = NSMutableAttributedString(string: clean.isEmpty ? "Neue Notiz" : clean, attributes: TextStyle.title.attributes(theme: theme))
        rich.append(NSAttributedString(string: "\n" + text, attributes: theme.bodyAttributes))
        var block = BlockRecord(kind: .text)
        block.rtf = RichTextCodec.rtfData(from: rich)
        let draft = NoteFile(meta: NoteMetadata(title: clean), body: NoteBody(blocks: [block]))
        let file = NoteDocument(file: draft, url: URL(fileURLWithPath: "/dev/null")).makeFile()
        let url = store.uniqueURL(in: store.rootURL, base: NoteStore.sanitize(file.meta.title.isEmpty ? "Neue Notiz" : file.meta.title))
        do {
            try file.write(to: url)
        } catch {
            throw Failure.notCreated(error.localizedDescription)
        }
        store.reload()
        guard let ref = store.notes.first(where: { $0.id == file.meta.id }) else { throw Failure.notCreated("nicht in der Bibliothek") }
        return ref
    }

    /// Notes whose title, tags or text contain every word of `query`; title hits first, then the newest.
    static func search(_ query: String, limit: Int = 50) -> [NoteRef] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return Array(NoteStore.shared.notes.sorted { $0.meta.modified > $1.meta.modified }.prefix(limit)) }
        let hits = NoteStore.shared.notes.filter { ref in
            let hay = (ref.meta.title + " " + ref.meta.tags.joined(separator: " ") + " " + ref.meta.searchText).lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
        return Array(hits.sorted {
            let a = terms.allSatisfy($0.meta.title.lowercased().contains), b = terms.allSatisfy($1.meta.title.lowercased().contains)
            return a != b ? a : $0.meta.modified > $1.meta.modified
        }.prefix(limit))
    }

    /// A note by id (UUID text, only as an id), exact title, else a search with exactly one hit. Empty or ambiguous
    /// references are refused, so a command never acts on some other note (#347).
    static func find(_ reference: String) throws -> NoteRef {
        let store = NoteStore.shared
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { throw Failure.notFound("") }
        if let id = UUID(uuidString: ref) {
            guard let note = store.notes.first(where: { $0.id == id }) else { throw Failure.notFound(ref) }
            return note
        }
        let exact = store.notes.filter { $0.meta.title.caseInsensitiveCompare(ref) == .orderedSame }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { throw Failure.ambiguous(ref, exact.count) }
        let hits = search(ref, limit: 2)
        guard hits.count == 1 else { throw hits.isEmpty ? Failure.notFound(ref) : Failure.ambiguous(ref, hits.count) }
        return hits[0]
    }

    static func open(_ ref: NoteRef) {
        QuickAccessSettings.showMainWindow(QuickAccessSettings.opener)
        NoteStore.shared.open(noteID: ref.id)
    }

    /// Appends text at the end of a note, like a quick capture (with date line). Returns what happened: saved, waiting
    /// in the queue, or only in the open editor because the note could not be saved yet (#351).
    @discardableResult
    static func append(_ text: String, to ref: NoteRef) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.empty }
        let result = CaptureService.shared.save(CaptureItem(text: text, target: .note(ref.id)))
        guard result.ok else { throw Failure.notCreated(result.message) }
        return result.message
    }
}

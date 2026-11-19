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

        var errorDescription: String? {
            switch self {
            case .notFound(let q): return "Keine Notiz „\(q)“ gefunden."
            case .notCreated(let why): return "Die Notiz konnte nicht angelegt werden: \(why)"
            case .empty: return "Es wurde kein Text übergeben."
            }
        }
    }

    /// A new note; its title is the first line. Returns the note.
    static func create(title: String, text: String = "") throws -> NoteRef {
        let store = NoteStore.shared
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty || !text.isEmpty else { throw Failure.empty }
        guard let ref = store.createNote(titled: clean.isEmpty ? "Neue Notiz" : clean, body: text) else {
            throw Failure.notCreated(store.lastError ?? "unbekannter Fehler")
        }
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

    /// A note by id (UUID text) or exact title, else the best search hit.
    static func find(_ reference: String) throws -> NoteRef {
        let store = NoteStore.shared
        if let id = UUID(uuidString: reference), let ref = store.notes.first(where: { $0.id == id }) { return ref }
        if let ref = store.notes.first(where: { $0.meta.title.caseInsensitiveCompare(reference) == .orderedSame }) { return ref }
        if let ref = search(reference, limit: 1).first { return ref }
        throw Failure.notFound(reference)
    }

    static func open(_ ref: NoteRef) {
        QuickAccessSettings.showMainWindow(QuickAccessSettings.opener)
        NoteStore.shared.open(noteID: ref.id)
    }

    /// Appends text at the end of a note, like a quick capture (with date line).
    static func append(_ text: String, to ref: NoteRef) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.empty }
        let result = CaptureService.shared.save(CaptureItem(text: text, target: .note(ref.id)))
        guard result.ok else { throw Failure.notCreated(result.message) }
    }
}

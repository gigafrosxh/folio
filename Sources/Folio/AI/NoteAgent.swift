import AppKit
import Foundation
import FolioCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What the assistant may do with notes when asked (#124): create, add text, link, tag, rename, move.
/// It never deletes anything, every change goes through the normal save (with version history), and
/// each action is listed under the answer.
@MainActor
enum NoteAgent {
    struct Action: Equatable, Sendable {
        var summary: String
        var noteID: UUID?
    }

    /// Actions of the running request, shown under the answer.
    static var log: [Action] = []

    // MARK: Operations (also used by tests)

    static func find(_ title: String) -> NoteRef? {
        let store = NoteStore.shared
        if let id = store.linkIndex.resolve(title) { return store.notes.first { $0.id == id } }
        // Only close matches („Portugal“ for „Urlaub Portugal“); a loose fuzzy hit could change the wrong note.
        let q = WikiLink.key(title)
        guard q.count >= 3 else { return nil }
        let close = store.notes.filter { let t = WikiLink.key($0.meta.title); return t.contains(q) || (t.count >= 3 && q.contains(t)) }
        return close.count == 1 ? close[0] : close.max { $0.meta.modified < $1.meta.modified }
    }

    @discardableResult
    static func createNote(title: String, text: String) -> String {
        let store = NoteStore.shared
        guard let ref = store.createNote(titled: title.trimmingCharacters(in: .whitespacesAndNewlines), body: text) else {
            return "Fehler: Die Notiz konnte nicht angelegt werden."
        }
        log.append(Action(summary: "Notiz „\(ref.meta.title)“ angelegt", noteID: ref.id))
        return "Notiz „\(ref.meta.title)“ angelegt."
    }

    @discardableResult
    static func append(to title: String, text: String) -> String {
        guard let ref = find(title) else { return "Fehler: Keine Notiz „\(title)“ gefunden." }
        guard let doc = document(ref) else { return "Fehler: „\(ref.meta.title)“ ist nicht lesbar." }
        let target = doc.blocks.last(where: { $0.kind == .text }) ?? {
            let b = BlockModel(kind: .text)
            doc.insert(b, after: doc.blocks.last?.id)
            return b
        }()
        let body = ThemeManager.shared.bodyAttributes
        let prefix = target.storage.length == 0 || target.storage.string.hasSuffix("\n") ? "" : "\n"
        target.storage.append(NSAttributedString(string: prefix + text, attributes: body))
        doc.markDirty()
        doc.saveNow()
        log.append(Action(summary: "Text in „\(ref.meta.title)“ ergänzt", noteID: ref.id))
        return "Text an „\(ref.meta.title)“ angefügt."
    }

    @discardableResult
    static func link(from: String, to: String) -> String {
        guard let a = find(from) else { return "Fehler: Keine Notiz „\(from)“ gefunden." }
        guard let b = find(to) else { return "Fehler: Keine Notiz „\(to)“ gefunden." }
        guard a.id != b.id else { return "Eine Notiz verweist nicht auf sich selbst." }
        if NoteStore.shared.linkIndex.outgoing(a.id).contains(b.id) {
            return "„\(a.meta.title)“ verweist schon auf „\(b.meta.title)“."
        }
        let result = append(to: a.meta.title, text: "Siehe auch: [[\(b.meta.title)]]")
        guard !result.hasPrefix("Fehler") else { return result }
        log.removeLast()
        log.append(Action(summary: "„\(a.meta.title)“ → „\(b.meta.title)“ verknüpft", noteID: a.id))
        return "„\(a.meta.title)“ verweist jetzt auf „\(b.meta.title)“."
    }

    @discardableResult
    static func addTag(_ tag: String, to title: String) -> String {
        let clean = tag.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).replacingOccurrences(of: " ", with: "-")
        guard !clean.isEmpty else { return "Fehler: Leerer Tag." }
        guard let ref = find(title) else { return "Fehler: Keine Notiz „\(title)“ gefunden." }
        if ref.meta.tags.contains(clean.lowercased()) { return "„\(ref.meta.title)“ hat #\(clean) schon." }
        let result = append(to: ref.meta.title, text: "#\(clean)")
        guard !result.hasPrefix("Fehler") else { return result }
        log.removeLast()
        log.append(Action(summary: "#\(clean) zu „\(ref.meta.title)“ hinzugefügt", noteID: ref.id))
        return "#\(clean) zu „\(ref.meta.title)“ hinzugefügt."
    }

    @discardableResult
    static func rename(_ title: String, to newTitle: String) -> String {
        let new = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty else { return "Fehler: Leerer Titel." }
        guard let ref = find(title), let doc = document(ref), let first = doc.blocks.first(where: { $0.kind == .text }) else {
            return "Fehler: Keine Notiz „\(title)“ gefunden."
        }
        let ns = first.storage.string as NSString
        let line = ns.lineRange(for: NSRange(location: 0, length: 0))
        let titleRange = NSRange(location: 0, length: line.length - (ns.substring(with: line).hasSuffix("\n") ? 1 : 0))
        let attrs = first.storage.length > 0 ? first.storage.attributes(at: 0, effectiveRange: nil) : TextStyle.title.attributes(theme: ThemeManager.shared)
        first.storage.replaceCharacters(in: titleRange, with: NSAttributedString(string: new, attributes: attrs))
        doc.markDirty()
        doc.saveNow()
        log.append(Action(summary: "„\(ref.meta.title)“ in „\(new)“ umbenannt", noteID: ref.id))
        return "„\(ref.meta.title)“ heißt jetzt „\(new)“."
    }

    @discardableResult
    static func move(_ title: String, toFolder folder: String) -> String {
        let store = NoteStore.shared
        guard let ref = find(title) else { return "Fehler: Keine Notiz „\(title)“ gefunden." }
        let parts = folder.split(separator: "/").map { NoteStore.sanitize(String($0)) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "Fehler: Kein Ordner angegeben." }
        let url = parts.reduce(store.rootURL) { $0.appendingPathComponent($1, isDirectory: true) }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store.move(ref.id, to: url)
        log.append(Action(summary: "„\(ref.meta.title)“ nach „\(parts.joined(separator: "/"))“ verschoben", noteID: ref.id))
        return "„\(ref.meta.title)“ liegt jetzt im Ordner „\(parts.joined(separator: "/"))“."
    }

    static func search(_ query: String) -> String {
        let hits = FuzzyMatch.rank(NoteStore.shared.notes, query: query) { $0.meta.title + " " + $0.meta.preview }.prefix(8)
        guard !hits.isEmpty else { return "Keine passenden Notizen." }
        return hits.map { "„\($0.meta.title)“ (Ordner \(NoteStore.shared.relativeFolderName($0.folderURL)))" }.joined(separator: "\n")
    }

    private static func document(_ ref: NoteRef) -> NoteDocument? {
        let store = NoteStore.shared
        if let doc = store.document(for: ref.id) { return doc }
        store.open(ref.url, id: ref.id)
        return store.document(for: ref.id)
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
enum NoteAgentTools {
    static var all: [any Tool] {
        [CreateNote(), AppendText(), LinkNotes(), AddTag(), RenameNote(), MoveNote(), FindNotes()]
    }

    struct CreateNote: Tool {
        let name = "notizAnlegen"
        let description = "Legt eine neue Notiz an."
        @Generable struct Arguments {
            @Guide(description: "Titel der neuen Notiz") var titel: String
            @Guide(description: "Inhalt der Notiz ohne Titel, darf leer sein") var text: String
        }
        func call(arguments: Arguments) async throws -> String {
            await MainActor.run { NoteAgent.createNote(title: arguments.titel, text: arguments.text) }
        }
    }

    struct AppendText: Tool {
        let name = "textAnfuegen"
        let description = "Fügt Text am Ende einer bestehenden Notiz an."
        @Generable struct Arguments {
            @Guide(description: "Titel der Notiz") var notiz: String
            @Guide(description: "Anzufügender Text") var text: String
        }
        func call(arguments: Arguments) async throws -> String {
            await MainActor.run { NoteAgent.append(to: arguments.notiz, text: arguments.text) }
        }
    }

    struct LinkNotes: Tool {
        let name = "notizenVerknuepfen"
        let description = "Verknüpft zwei Notizen: die erste verweist danach mit einem [[Link]] auf die zweite."
        @Generable struct Arguments {
            @Guide(description: "Titel der Notiz, die den Link bekommt") var von: String
            @Guide(description: "Titel der Notiz, auf die verwiesen wird") var nach: String
        }
        func call(arguments: Arguments) async throws -> String {
            await MainActor.run { NoteAgent.link(from: arguments.von, to: arguments.nach) }
        }
    }

    struct AddTag: Tool {
        let name = "tagHinzufuegen"
        let description = "Gibt einer Notiz einen #Tag."
        @Generable struct Arguments {
            @Guide(description: "Titel der Notiz") var notiz: String
            @Guide(description: "Tag ohne #") var tag: String
        }
        func call(arguments: Arguments) async throws -> String {
            await MainActor.run { NoteAgent.addTag(arguments.tag, to: arguments.notiz) }
        }
    }

    struct RenameNote: Tool {
        let name = "notizUmbenennen"
        let description = "Ändert den Titel einer Notiz."
        @Generable struct Arguments {
            @Guide(description: "Bisheriger Titel") var notiz: String
            @Guide(description: "Neuer Titel") var neuerTitel: String
        }
        func call(arguments: Arguments) async throws -> String {
            await MainActor.run { NoteAgent.rename(arguments.notiz, to: arguments.neuerTitel) }
        }
    }

    struct MoveNote: Tool {
        let name = "notizVerschieben"
        let description = "Verschiebt eine Notiz in einen Ordner der Bibliothek; fehlende Ordner werden angelegt."
        @Generable struct Arguments {
            @Guide(description: "Titel der Notiz") var notiz: String
            @Guide(description: "Ordnerpfad, z. B. Projekte/Alt") var ordner: String
        }
        func call(arguments: Arguments) async throws -> String {
            await MainActor.run { NoteAgent.move(arguments.notiz, toFolder: arguments.ordner) }
        }
    }

    struct FindNotes: Tool {
        let name = "notizenSuchen"
        let description = "Sucht Notizen nach Titel oder Inhalt und liefert ihre genauen Titel."
        @Generable struct Arguments {
            @Guide(description: "Suchbegriff") var suche: String
        }
        func call(arguments: Arguments) async throws -> String {
            await MainActor.run { NoteAgent.search(arguments.suche) }
        }
    }
}
#endif

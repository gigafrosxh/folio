import Foundation

/// What the widgets may know about the library (#84). Folio writes it after changes; the widget
/// extension only reads it and never opens a `.folio` file, so widgets can not change notes.
///
/// Privacy (#83): previews and checklist items are only included when the user allowed widget
/// contents in the settings. Otherwise widgets show titles, folders, dates and counts.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Note: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var title: String
        public var folder: String
        public var modified: Date
        public var pinned: Bool
        /// Only with `showsContent`.
        public var preview: String?

        public init(id: UUID, title: String, folder: String, modified: Date, pinned: Bool, preview: String? = nil) {
            self.id = id
            self.title = title
            self.folder = folder
            self.modified = modified
            self.pinned = pinned
            self.preview = preview
        }

        public var link: URL { URL(string: "folio://note/\(id.uuidString)")! }
    }

    public struct Checklist: Codable, Equatable, Sendable, Identifiable {
        public struct Item: Codable, Equatable, Sendable {
            public var text: String
            public var done: Bool
            public init(text: String, done: Bool) { self.text = text; self.done = done }
        }
        public var noteID: UUID
        public var title: String
        public var done: Int
        public var total: Int
        /// The first open items (and some done ones); empty without `showsContent`.
        public var items: [Item]
        public var id: UUID { noteID }

        public init(noteID: UUID, title: String, done: Int, total: Int, items: [Item] = []) {
            self.noteID = noteID
            self.title = title
            self.done = done
            self.total = total
            self.items = items
        }

        public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
        public var link: URL { URL(string: "folio://note/\(noteID.uuidString)")! }
    }

    public static let currentVersion = 1

    public var version: Int
    public var generated: Date
    public var libraryName: String
    /// False when the library folder is missing (e.g. an unplugged drive); widgets say so.
    public var libraryAvailable: Bool
    public var showsContent: Bool
    public var pinned: [Note]
    public var recent: [Note]
    /// All notes (newest first, capped) for picking one in a widget's settings.
    public var notes: [Note]
    public var checklists: [Checklist]
    /// Chosen in Folio („Im Widget zeigen“); nil = automatic (#81, #82).
    public var featuredNoteID: UUID?
    public var featuredChecklistID: UUID?

    public init(generated: Date = Date(), libraryName: String, libraryAvailable: Bool = true, showsContent: Bool = false,
                pinned: [Note] = [], recent: [Note] = [], notes: [Note] = [], checklists: [Checklist] = []) {
        version = Self.currentVersion
        self.generated = generated
        self.libraryName = libraryName
        self.libraryAvailable = libraryAvailable
        self.showsContent = showsContent
        self.pinned = pinned
        self.recent = recent
        self.notes = notes
        self.checklists = checklists
    }

    public func note(_ id: UUID) -> Note? { notes.first { $0.id == id } ?? pinned.first { $0.id == id } ?? recent.first { $0.id == id } }
    public func checklist(_ id: UUID) -> Checklist? { checklists.first { $0.noteID == id } }

    /// The chosen checklist, else the most recently edited one with open items, else any.
    public var featuredChecklist: Checklist? {
        if let id = featuredChecklistID, let c = checklist(id) { return c }
        return checklists.first { $0.done < $0.total } ?? checklists.first
    }

    /// The chosen note, else a different one every day.
    public func featuredNote(on date: Date = Date()) -> Note? {
        if let id = featuredNoteID, let n = note(id) { return n }
        return noteOfTheDay(on: date)
    }

    /// A note that stays the same for a whole day and changes the next (#82).
    public func noteOfTheDay(on date: Date = Date(), calendar: Calendar = .current) -> Note? {
        let pool = notes.isEmpty ? recent : notes
        guard !pool.isEmpty else { return nil }
        let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
        let sorted = pool.sorted { $0.id.uuidString < $1.id.uuidString }
        return sorted[day % sorted.count]
    }

    /// The same data without any note contents, as widgets show it in privacy mode.
    public func withoutContent() -> WidgetSnapshot {
        var s = self
        s.showsContent = false
        func strip(_ n: Note) -> Note { var n = n; n.preview = nil; return n }
        s.pinned = pinned.map(strip)
        s.recent = recent.map(strip)
        s.notes = notes.map(strip)
        s.checklists = checklists.map { var c = $0; c.items = []; return c }
        return s
    }

    /// Example data for the widget gallery.
    public static let placeholder = WidgetSnapshot(
        libraryName: "Folio", showsContent: true,
        pinned: [Note(id: UUID(), title: "Projektideen", folder: "Notizen", modified: Date(), pinned: true, preview: "Widgets für Folio"),
                 Note(id: UUID(), title: "Einkauf", folder: "Privat", modified: Date(), pinned: true, preview: "Äpfel, Milch")],
        recent: [Note(id: UUID(), title: "Besprechung", folder: "Arbeit", modified: Date(), pinned: false, preview: "Nächste Schritte")],
        checklists: [Checklist(noteID: UUID(), title: "Einkauf", done: 2, total: 5,
                               items: [.init(text: "Milch", done: false), .init(text: "Brot", done: false), .init(text: "Äpfel", done: true)])])
}

/// Counts the checkboxes Folio writes into text ("☐ " open, "☑ " done).
public enum ChecklistParser {
    public static func parse(_ text: String, maxItems: Int = 8) -> (done: Int, total: Int, items: [WidgetSnapshot.Checklist.Item]) {
        var done = 0, total = 0
        var open: [WidgetSnapshot.Checklist.Item] = [], finished: [WidgetSnapshot.Checklist.Item] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let isOpen = line.hasPrefix("☐")
            guard isOpen || line.hasPrefix("☑") else { continue }
            total += 1
            let label = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            if isOpen { open.append(.init(text: label, done: false)) } else { done += 1; finished.append(.init(text: label, done: true)) }
        }
        // Open items first: they are what the widget is for.
        return (done, total, Array((open + finished).prefix(maxItems)))
    }
}

/// Where the snapshot lives: in Folio's support folder, outside the library. The sandboxed widget
/// reads it through a read-only exception for exactly this folder.
public enum WidgetSnapshotStore {
    public static let fileName = "snapshot.json"

    /// The real home folder, also inside the widget's sandbox (where NSHomeDirectory is the container).
    public static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir), isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var defaultFolder: URL {
        if let override = ProcessInfo.processInfo.environment["FOLIO_WIDGET_FOLDER"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return realHome.appendingPathComponent("Library/Application Support/Folio/Widgets", isDirectory: true)
    }

    public static func write(_ snapshot: WidgetSnapshot, to folder: URL = defaultFolder) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(snapshot)
        // Atomic, so the widget never reads half a file.
        try data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }

    public enum ReadError: Error, Equatable { case missing, unreadable }

    public static func read(from folder: URL = defaultFolder) -> Result<WidgetSnapshot, ReadError> {
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return .failure(.missing) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data), snapshot.version <= WidgetSnapshot.currentVersion else {
            return .failure(.unreadable)
        }
        // Defense in depth: content the user did not allow never reaches a view.
        return .success(snapshot.showsContent ? snapshot : snapshot.withoutContent())
    }
}

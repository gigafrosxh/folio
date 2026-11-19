import AppIntents
import FolioCore

// Shortcuts actions (#70). The App Intents metadata comes from scripts/widget-intents-metadata.sh (no Xcode project).

struct NoteEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Folio-Notiz"
    static let defaultQuery = NoteEntityQuery()
    var id: UUID
    @Property(title: "Titel") var title: String
    @Property(title: "Ordner") var folder: String

    init(_ ref: NoteRef) {
        id = ref.id
        title = ref.meta.title
        folder = ref.url.deletingLastPathComponent().lastPathComponent
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "\(folder)") }
}

struct NoteEntityQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [NoteEntity] {
        NoteStore.shared.notes.filter { identifiers.contains($0.id) }.map(NoteEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [NoteEntity] {
        NoteAutomation.search(string).map(NoteEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [NoteEntity] {
        NoteAutomation.search("", limit: 30).map(NoteEntity.init)
    }
}

struct CreateNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Notiz erstellen"
    static let description = IntentDescription("Legt in Folio eine neue Notiz an; die erste Zeile ist der Titel.")
    @Parameter(title: "Titel") var noteTitle: String
    @Parameter(title: "Text", default: "") var text: String

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> {
        .result(value: NoteEntity(try NoteAutomation.create(title: noteTitle, text: text)))
    }
}

struct SearchNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Notizen suchen"
    static let description = IntentDescription("Findet Folio-Notizen, die alle Wörter enthalten (Titel, Tags, Text).")
    @Parameter(title: "Suchbegriff") var query: String

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[NoteEntity]> {
        .result(value: NoteAutomation.search(query).map(NoteEntity.init))
    }
}

struct OpenNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Notiz öffnen"
    static let description = IntentDescription("Öffnet eine Notiz in Folio.")
    static let openAppWhenRun = true
    @Parameter(title: "Notiz") var note: NoteEntity

    @MainActor func perform() async throws -> some IntentResult {
        NoteAutomation.open(try NoteAutomation.find(note.id.uuidString))
        return .result()
    }
}

struct AppendToNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "An Notiz anhängen"
    static let description = IntentDescription("Hängt Text mit Datumszeile ans Ende einer Notiz an.")
    @Parameter(title: "Notiz") var note: NoteEntity
    @Parameter(title: "Text") var text: String

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try NoteAutomation.append(text, to: try NoteAutomation.find(note.id.uuidString)))
    }
}

struct FolioShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CreateNoteIntent(), phrases: ["Neue Notiz in \(.applicationName)"], shortTitle: "Notiz erstellen", systemImageName: "square.and.pencil")
        AppShortcut(intent: SearchNotesIntent(), phrases: ["In \(.applicationName) suchen"], shortTitle: "Notizen suchen", systemImageName: "magnifyingglass")
    }
}

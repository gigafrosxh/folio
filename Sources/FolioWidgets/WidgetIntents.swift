import AppIntents
import WidgetKit
import FolioWidgetData

// „Widget bearbeiten“ (#122): pick the note of „Notiz des Tages“ and the checklist right on the widget. The choices
// come from the snapshot Folio writes (titles only); without a choice the widget keeps showing Folio's pick.
// The App Intents metadata is generated in scripts/build-app.sh (no Xcode project needed).

struct WidgetNoteEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Notiz"
    static let defaultQuery = WidgetNoteQuery()
    var id: String
    var title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct WidgetNoteQuery: EntityQuery {
    private var notes: [WidgetSnapshot.Note] {
        guard case .success(let s) = WidgetSnapshotStore.read() else { return [] }
        var seen = Set<UUID>()
        return (s.pinned + s.recent + s.notes).filter { seen.insert($0.id).inserted }
    }

    func entities(for identifiers: [String]) async throws -> [WidgetNoteEntity] {
        notes.filter { identifiers.contains($0.id.uuidString) }.map { WidgetNoteEntity(id: $0.id.uuidString, title: $0.title) }
    }

    func suggestedEntities() async throws -> [WidgetNoteEntity] {
        notes.prefix(50).map { WidgetNoteEntity(id: $0.id.uuidString, title: $0.title) }
    }
}

struct WidgetChecklistEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Checkliste"
    static let defaultQuery = WidgetChecklistQuery()
    var id: String
    var title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct WidgetChecklistQuery: EntityQuery {
    private var checklists: [WidgetSnapshot.Checklist] {
        guard case .success(let s) = WidgetSnapshotStore.read() else { return [] }
        return s.checklists
    }

    func entities(for identifiers: [String]) async throws -> [WidgetChecklistEntity] {
        checklists.filter { identifiers.contains($0.noteID.uuidString) }.map { WidgetChecklistEntity(id: $0.noteID.uuidString, title: $0.title) }
    }

    func suggestedEntities() async throws -> [WidgetChecklistEntity] {
        checklists.map { WidgetChecklistEntity(id: $0.noteID.uuidString, title: $0.title) }
    }
}

struct PickNoteIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Notiz wählen"
    static let description = IntentDescription("Welche Notiz das Widget zeigt. Leer: die in Folio gewählte oder jeden Tag eine andere.")
    @Parameter(title: "Notiz") var note: WidgetNoteEntity?
    init() {}
}

struct PickChecklistIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Checkliste wählen"
    static let description = IntentDescription("Welche Checkliste das Widget zeigt. Leer: die in Folio gewählte.")
    @Parameter(title: "Checkliste") var checklist: WidgetChecklistEntity?
    init() {}
}

/// Snapshot entries with the widget's own choice applied (the snapshot file itself is never changed).
struct ConfiguredProvider<Intent: WidgetConfigurationIntent>: AppIntentTimelineProvider {
    var apply: (Intent, inout WidgetSnapshot) -> Void

    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: Date(), result: .success(.placeholder)) }

    func snapshot(for configuration: Intent, in context: Context) async -> SnapshotEntry {
        context.isPreview ? placeholder(in: context) : entry(configuration, date: Date())
    }

    func timeline(for configuration: Intent, in context: Context) async -> Timeline<SnapshotEntry> {
        let now = Date()
        let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 1), matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
        return Timeline(entries: [entry(configuration, date: now)], policy: .after(min(midnight, now.addingTimeInterval(3600))))
    }

    private func entry(_ configuration: Intent, date: Date) -> SnapshotEntry {
        SnapshotEntry(date: date, result: WidgetSnapshotStore.read().map { snapshot in
            var s = snapshot
            apply(configuration, &s)
            return s
        })
    }
}

extension ConfiguredProvider where Intent == PickNoteIntent {
    static var note: Self { Self { intent, s in if let id = intent.note.flatMap({ UUID(uuidString: $0.id) }), s.note(id) != nil { s.featuredNoteID = id } } }
}

extension ConfiguredProvider where Intent == PickChecklistIntent {
    static var checklist: Self { Self { intent, s in if let id = intent.checklist.flatMap({ UUID(uuidString: $0.id) }), s.checklist(id) != nil { s.featuredChecklistID = id } } }
}

import SwiftUI
import WidgetKit
import FolioWidgetData
import FolioWidgetUI

/// Folio's desktop widgets (#78–#84). They only read the snapshot Folio writes; clicks open Folio
/// through folio:// links, so a widget never changes a note itself.
@main
struct FolioWidgets: WidgetBundle {
    var body: some Widget {
        PinnedNotesWidget()
        RecentNotesWidget()
        QuickCaptureWidget()
        ChecklistWidget()
        NoteOfTheDayWidget()
    }
}

struct SnapshotEntry: TimelineEntry {
    var date: Date
    var result: Result<WidgetSnapshot, WidgetSnapshotStore.ReadError>
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: Date(), result: .success(.placeholder)) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        // The widget gallery shows example data rather than real notes.
        completion(context.isPreview ? placeholder(in: context) : SnapshotEntry(date: Date(), result: WidgetSnapshotStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // Folio asks for a reload after every change; the daily refresh is for „Notiz des Tages“
        // and relative dates.
        let now = Date()
        let entry = SnapshotEntry(date: now, result: WidgetSnapshotStore.read())
        let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 1), matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(min(midnight, now.addingTimeInterval(3600)))))
    }
}

private extension WidgetFamily {
    var size: WidgetSize {
        switch self {
        case .systemSmall: return .small
        case .systemMedium: return .medium
        default: return .large
        }
    }
}

/// Snapshot or a message, with the standard widget background.
private struct SnapshotView<Content: View>: View {
    var entry: SnapshotEntry
    @ViewBuilder var content: (WidgetSnapshot) -> Content
    var body: some View {
        Group {
            switch entry.result {
            case .success(let snapshot): content(snapshot)
            case .failure(let error): WidgetMessage.forError(error)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct PinnedNotesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "de.daniel.folio.pinned", provider: SnapshotProvider()) { entry in
            FamilyReader { family in
                SnapshotView(entry: entry) { NoteListWidgetView(kind: .pinned, snapshot: $0, size: family.size) }
            }
        }
        .configurationDisplayName("Angepinnte Notizen")
        .description("Deine angepinnten Notizen. Ein Klick öffnet die Notiz in Folio.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct RecentNotesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "de.daniel.folio.recent", provider: SnapshotProvider()) { entry in
            FamilyReader { family in
                SnapshotView(entry: entry) { NoteListWidgetView(kind: .recent, snapshot: $0, size: family.size) }
            }
        }
        .configurationDisplayName("Letzte Notizen")
        .description("Die zuletzt bearbeiteten Notizen mit Ordner und Datum.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct QuickCaptureWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "de.daniel.folio.capture", provider: SnapshotProvider()) { _ in
            FamilyReader { family in
                QuickCaptureWidgetView(size: family.size).containerBackground(.fill.tertiary, for: .widget)
            }
        }
        .configurationDisplayName("Schnellnotiz")
        .description("Öffnet die Schnellerfassung oder legt eine neue Notiz an.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ChecklistWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "de.daniel.folio.checklist", provider: SnapshotProvider()) { entry in
            FamilyReader { family in
                SnapshotView(entry: entry) { ChecklistWidgetView(checklist: $0.featuredChecklist, snapshot: $0, size: family.size) }
            }
        }
        .configurationDisplayName("Checkliste")
        .description("Fortschritt einer Checkliste. Welche, wählst du in Folio über „Im Widget zeigen“.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct NoteOfTheDayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "de.daniel.folio.daily", provider: SnapshotProvider()) { entry in
            FamilyReader { family in
                SnapshotView(entry: entry) {
                    NoteOfTheDayWidgetView(note: $0.featuredNote(on: entry.date), snapshot: $0, hideContent: !$0.showsContent, size: family.size)
                }
            }
        }
        .configurationDisplayName("Notiz des Tages")
        .description("Jeden Tag eine andere Notiz oder die in Folio gewählte. Inhalte nur, wenn du sie in Folio erlaubst.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// Reads the widget family inside the configuration closure.
private struct FamilyReader<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    @ViewBuilder var content: (WidgetFamily) -> Content
    var body: some View { content(family) }
}

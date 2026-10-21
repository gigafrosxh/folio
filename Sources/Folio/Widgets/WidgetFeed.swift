import Combine
import Foundation
import FolioCore
import FolioWidgetData
import WidgetKit

/// Keeps the widgets' snapshot up to date (#84). It is built from the note list Folio already has in
/// memory; no `.folio` file is opened or written for it.
@MainActor
final class WidgetFeed {
    static let shared = WidgetFeed()
    private var cancellables: Set<AnyCancellable> = []
    private var last: WidgetSnapshot?

    /// Test runs against a throwaway library keep their snapshot there, never in the real widgets.
    var folder: URL {
        let env = ProcessInfo.processInfo.environment
        if env["FOLIO_WIDGET_FOLDER"] == nil, env["FOLIO_LIBRARY"] != nil {
            return LibraryData.folder(NoteStore.shared.rootURL, "widgets")
        }
        return WidgetSnapshotStore.defaultFolder
    }

    func start() {
        let store = NoteStore.shared
        store.$notes.map { _ in () }
            .merge(with: ThemeManager.shared.$settings.map { _ in () })
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] in self?.update() }
            .store(in: &cancellables)
        update()
    }

    /// Writes the snapshot when it changed and asks WidgetKit to redraw.
    func update() {
        let snapshot = Self.build(store: NoteStore.shared, settings: ThemeManager.shared.settings)
        var comparable = snapshot
        comparable.generated = last?.generated ?? snapshot.generated
        guard comparable != last else { return }
        do {
            try WidgetSnapshotStore.write(snapshot, to: folder)
            last = snapshot
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // Widgets keep their last state; nothing to bother the user with.
        }
    }

    static func build(store: NoteStore, settings: ThemeSettings, now: Date = Date()) -> WidgetSnapshot {
        let show = settings.widgetShowContent
        let available = FileManager.default.fileExists(atPath: store.rootURL.path)
        let byDate = store.notes.sorted { $0.meta.modified > $1.meta.modified }
        func note(_ ref: NoteRef) -> WidgetSnapshot.Note {
            WidgetSnapshot.Note(id: ref.id, title: ref.meta.title, folder: store.relativeFolderName(ref.folderURL),
                                modified: ref.meta.modified, pinned: ref.meta.pinned,
                                preview: show ? String(ref.meta.preview.prefix(240)) : nil)
        }
        var checklists: [WidgetSnapshot.Checklist] = []
        for ref in byDate where ref.meta.searchText.contains("☐") || ref.meta.searchText.contains("☑") {
            let parsed = ChecklistParser.parse(ref.meta.searchText)
            guard parsed.total > 0 else { continue }
            checklists.append(.init(noteID: ref.id, title: ref.meta.title, done: parsed.done, total: parsed.total,
                                    items: show ? parsed.items : []))
            if checklists.count == 30 { break }
        }
        var snapshot = WidgetSnapshot(generated: now, libraryName: store.rootURL.lastPathComponent, libraryAvailable: available,
                                      showsContent: show,
                                      pinned: byDate.filter(\.meta.pinned).prefix(10).map(note),
                                      recent: byDate.prefix(10).map(note),
                                      notes: byDate.prefix(200).map(note),
                                      checklists: checklists)
        snapshot.featuredNoteID = UUID(uuidString: settings.widgetNote)
        snapshot.featuredChecklistID = UUID(uuidString: settings.widgetChecklist)
        return snapshot
    }
}

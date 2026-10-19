import AppKit
import SwiftUI

struct NoteListView: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        let notes = store.filteredNotes
        List(selection: $store.selectedNoteID) {
            ForEach(notes) { note in
                NoteRow(note: note, showFolder: !isFolderSelected)
                    .tag(note.id)
                    .draggable(note.id.uuidString)
                    .contextMenu { menu(for: note) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
        .overlay {
            if notes.isEmpty {
                ContentUnavailableView(store.searchText.isEmpty ? "Keine Notizen" : "Keine Treffer",
                                       systemImage: store.searchText.isEmpty ? "note.text" : "magnifyingglass",
                                       description: Text(store.searchText.isEmpty ? "Mit ⌘N legst du eine neue Notiz an." : "Für „\(store.searchText)“ wurde nichts gefunden."))
            }
        }
        .navigationTitle(title)
        .navigationSubtitle("\(notes.count) Notiz\(notes.count == 1 ? "" : "en")")
        .onDeleteCommand {
            if let id = store.selectedNoteID { store.delete(id) }
        }
    }

    private var isFolderSelected: Bool {
        if case .folder = store.sidebarSelection { return true }
        return false
    }

    private var title: String {
        switch store.sidebarSelection ?? .all {
        case .all: return "Alle Notizen"
        case .pinned: return "Angepinnt"
        case .folder(let url): return url.lastPathComponent
        case .tag(let t): return "#\(t)"
        }
    }

    @ViewBuilder
    private func menu(for note: NoteRef) -> some View {
        Button(note.meta.pinned ? "Loslösen" : "Anpinnen") { store.togglePin(note.id) }
        Menu("Bewegen nach") {
            ForEach(store.allFolderURLs, id: \.self) { url in
                Button(store.relativeFolderName(url)) { store.move(note.id, to: url) }
            }
        }
        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
        Divider()
        Button("Löschen", role: .destructive) { store.delete(note.id) }
    }
}

struct NoteRow: View {
    var note: NoteRef
    var showFolder: Bool
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if note.meta.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(theme.accent)
                }
                Text(note.meta.title.isEmpty ? "Neue Notiz" : note.meta.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(dateString)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.8))
                Text(note.meta.preview.isEmpty ? "Kein zusätzlicher Text" : note.meta.preview)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if showFolder || !note.meta.tags.isEmpty {
                HStack(spacing: 4) {
                    if showFolder {
                        Label(note.folderURL.lastPathComponent, systemImage: "folder")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(note.meta.tags.prefix(3), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.accent)
                    }
                }
            }
        }
        .padding(.vertical, 5)
    }

    private var dateString: String {
        let d = note.meta.modified
        if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(d) { return "Gestern" }
        return d.formatted(.dateTime.day().month(.twoDigits).year(.twoDigits))
    }
}

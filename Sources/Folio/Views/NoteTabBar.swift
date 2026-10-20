import AppKit
import SwiftUI
import FolioCore

/// Tabs of the main window (#11): one per open note, shown once more than one note is open.
struct NoteTabBar: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(store.tabs, id: \.self) { id in tab(id) }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)
            Button { store.createNoteInNewTab() } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .helpLabel("Neue Notiz in neuem Tab (⌘T)")
            .padding(.trailing, 8)
        }
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
    }

    private func title(_ id: UUID) -> String {
        let meta = store.document(for: id)?.meta ?? store.notes.first { $0.id == id }?.meta ?? store.templates.first { $0.id == id }?.meta
        let t = meta?.title ?? ""
        return t.isEmpty ? "Ohne Titel" : t
    }

    private func tab(_ id: UUID) -> some View {
        let selected = store.selectedNoteID == id
        return HStack(spacing: 6) {
            Text(title(id))
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 170, alignment: .leading)
            Button { store.closeTab(id) } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).frame(width: 16, height: 16)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .helpLabel("Tab schließen")
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(selected ? theme.accent.opacity(0.2) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { store.selectedNoteID = id }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab \(title(id))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { store.selectedNoteID = id }
        .contextMenu {
            Button("Rechts daneben öffnen") { store.openInSplit(id) }
            Button("In neuem Fenster öffnen") { openWindow(id: "note", value: id) }
            Divider()
            Button("Tab schließen") { store.closeTab(id) }
            Button("Andere Tabs schließen") { for other in store.tabs where other != id { store.closeTab(other) } }
        }
    }
}

/// A note in its own window (#11). Several windows, tabs and the split view share one document per note.
struct NoteWindowView: View {
    var noteID: UUID?
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager
    @StateObject private var windowState = WindowState()

    var body: some View {
        Group {
            if let id = noteID, let doc = store.document(for: id) {
                NoteEditorView(doc: doc)
                    .id(ObjectIdentifier(doc))
                    .navigationTitle(doc.meta.title.isEmpty ? "Notiz" : doc.meta.title)
            } else if let id = noteID, let damaged = store.failures[id] {
                DamagedNoteView(damaged: damaged)
            } else {
                ContentUnavailableView("Notiz nicht mehr vorhanden", systemImage: "note.text",
                                       description: Text("Sie wurde gelöscht oder in den Papierkorb gelegt."))
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(Color(nsColor: .textBackgroundColor))
        .background(WindowAccessor(window: $windowState.window))
        .environmentObject(windowState)
        .fontDesign(.rounded)
        .onAppear { if let id = noteID { store.windowOpened(id) } }
        .onDisappear { if let id = noteID { store.windowClosed(id) } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let w = note.object as? NSWindow, w === windowState.window, let id = noteID { store.focusedNoteID = id }
        }
    }
}

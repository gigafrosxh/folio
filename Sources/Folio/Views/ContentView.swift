import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } content: {
            NoteListView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            Group {
                if let doc = store.currentDocument {
                    NoteEditorView(doc: doc)
                        .id(doc.id)
                } else {
                    ContentUnavailableView {
                        Label("Keine Notiz ausgewählt", systemImage: "square.and.pencil")
                    } description: {
                        Text("Wähle links eine Notiz oder lege eine neue an.")
                    } actions: {
                        Button("Neue Notiz") { store.createNote() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if let doc = store.currentDocument {
                        Button {
                            store.togglePin(doc.id)
                        } label: {
                            Label(doc.meta.pinned ? "Loslösen" : "Anpinnen", systemImage: doc.meta.pinned ? "pin.slash" : "pin")
                        }
                        .help(doc.meta.pinned ? "Loslösen" : "Anpinnen")
                        ShareLink(item: doc.url) { Label("Teilen", systemImage: "square.and.arrow.up") }
                        Button(role: .destructive) {
                            store.delete(doc.id)
                        } label: {
                            Label("Löschen", systemImage: "trash")
                        }
                        .help("In den Papierkorb legen")
                    }
                }
            }
        }
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Suchen")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    store.createNote(initialTag: currentTag)
                } label: {
                    Label("Neue Notiz", systemImage: "square.and.pencil")
                }
                .help("Neue Notiz (⌘N)")
            }
        }
        .alert("Fehler", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK") {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var currentTag: String? {
        if case .tag(let t) = store.sidebarSelection { return t }
        return nil
    }
}

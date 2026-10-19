import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager
    @State private var newFolderParent: URL?
    @State private var showNewFolder = false
    @State private var renaming: URL?
    @State private var folderName = ""
    @State private var showImport = false

    var body: some View {
        List(selection: $store.sidebarSelection) {
            Section("Bibliothek") {
                Label("Alle Notizen", systemImage: "note.text")
                    .badge(store.notes.count)
                    .tag(SidebarItem.all)
                Label("Angepinnt", systemImage: "pin")
                    .badge(store.notes.filter(\.meta.pinned).count)
                    .tag(SidebarItem.pinned)
            }

            Section("Ordner") {
                OutlineGroup(store.folders, children: \.children) { folder in
                    folderRow(folder)
                }
            }

            if !store.tagCounts.isEmpty {
                Section("Tags") {
                    TagCloud(tags: store.tagCounts, selection: $store.sidebarSelection)
                        .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
                        .selectionDisabled()
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    newFolderParent = nil
                    folderName = ""
                    showNewFolder = true
                } label: {
                    Label("Neuer Ordner", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                Menu {
                    Button("Apple Notizen importieren…") { showImport = true }
                    Button("Bibliothek im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([store.rootURL]) }
                    Button("Neu laden") { store.reload() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .alert(newFolderParent == nil ? "Neuer Ordner" : "Neuer Unterordner", isPresented: $showNewFolder) {
            TextField("Name", text: $folderName)
            Button("Anlegen") { if !folderName.isEmpty { store.createFolder(named: folderName, in: newFolderParent) } }
            Button("Abbrechen", role: .cancel) {}
        }
        .alert("Ordner umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $folderName)
            Button("Umbenennen") { if let url = renaming, !folderName.isEmpty { store.renameFolder(url, to: folderName) } }
            Button("Abbrechen", role: .cancel) {}
        }
        .sheet(isPresented: $showImport) {
            ImportView().environmentObject(store).environmentObject(theme)
        }
        .onReceive(NotificationCenter.default.publisher(for: .folioShowImport)) { _ in showImport = true }
        .onReceive(NotificationCenter.default.publisher(for: .folioNewFolder)) { _ in
            if case .folder(let url) = store.sidebarSelection { newFolderParent = url } else { newFolderParent = nil }
            folderName = ""
            showNewFolder = true
        }
    }

    private func folderRow(_ folder: FolderNode) -> some View {
        Label(folder.name, systemImage: "folder")
            .badge(store.noteCount(in: folder.url))
            .tag(SidebarItem.folder(folder.url))
            .dropDestination(for: String.self) { items, _ in
                var moved = false
                for item in items {
                    if let id = UUID(uuidString: item) { store.move(id, to: folder.url); moved = true }
                }
                return moved
            }
            .contextMenu {
                Button("Neue Notiz hier") { store.createNote(in: folder.url) }
                Button("Neuer Unterordner…") {
                    newFolderParent = folder.url
                    folderName = ""
                    showNewFolder = true
                }
                Button("Umbenennen…") {
                    folderName = folder.name
                    renaming = folder.url
                }
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
                Divider()
                Button("In den Papierkorb legen", role: .destructive) { store.deleteFolder(folder.url) }
            }
    }
}

/// Tags as floating chips that wrap across lines.
struct TagCloud: View {
    var tags: [(tag: String, count: Int)]
    @Binding var selection: SidebarItem?
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.tag) { item in
                let selected = selection == .tag(item.tag)
                Button {
                    selection = selected ? .all : .tag(item.tag)
                } label: {
                    HStack(spacing: 3) {
                        Text("#\(item.tag)")
                        Text("\(item.count)").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(selected ? theme.accent.opacity(0.35) : theme.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 200
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension Notification.Name {
    static let folioShowImport = Notification.Name("folio.showImport")
    static let folioNewFolder = Notification.Name("folio.newFolder")
}

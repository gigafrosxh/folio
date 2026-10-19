import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Floating sidebar panel: search, library, folder tree and tag chips.
struct SidebarView: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var windowState: WindowState
    @State private var newFolderParent: URL?
    @State private var showNewFolder = false
    @State private var renaming: URL?
    @State private var folderName = ""
    @State private var showImport = false
    @State private var collapsed: Set<URL> = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                WindowControls(window: windowState.window)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)

            searchField
                .padding(.horizontal, 10)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        row(icon: "tray.full", title: "Alle Notizen", count: store.notes.count, item: .all)
                        row(icon: "pin", title: "Angepinnt", count: store.notes.filter(\.meta.pinned).count, item: .pinned)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        sectionTitle("Ordner")
                        ForEach(flatFolders, id: \.node.url) { entry in
                            folderRow(entry.node, depth: entry.depth)
                        }
                    }

                    if !store.tagCounts.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionTitle("Tags")
                            TagCloud(tags: store.tagCounts, selection: $store.sidebarSelection)
                                .padding(.horizontal, 4)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            HStack {
                Button {
                    newFolderParent = nil
                    folderName = ""
                    showNewFolder = true
                } label: {
                    Label("Neuer Ordner", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Menu {
                    Button("Apple Notizen importieren…") { showImport = true }
                    Button("Bibliothek im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([store.rootURL]) }
                    Button("Neu laden") { store.reload() }
                    Divider()
                    SettingsLink { Text("Einstellungen…") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .panel(theme: theme, fill: Color(nsColor: .controlBackgroundColor))
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
        .onReceive(NotificationCenter.default.publisher(for: .folioFocusSearch)) { _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .folioNewFolder)) { _ in
            if case .folder(let url) = store.sidebarSelection { newFolderParent = url } else { newFolderParent = nil }
            folderName = ""
            showNewFolder = true
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField("Suchen", text: $store.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !store.searchText.isEmpty {
                Button { store.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }

    private func row(icon: String, title: String, count: Int, item: SidebarItem, depth: Int = 0,
                     hasChildren: Bool = false, url: URL? = nil) -> some View {
        let selected = store.sidebarSelection == item
        return HStack(spacing: 8) {
            if hasChildren, let url {
                Button {
                    if collapsed.contains(url) { collapsed.remove(url) } else { collapsed.insert(url) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(collapsed.contains(url) ? 0 : 90))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: depth > 0 || url != nil ? 12 : 0)
            }
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(theme.accent)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 8 + CGFloat(depth) * 16)
        .padding(.trailing, 8)
        .frame(height: 32)
        .background(selected ? theme.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { store.sidebarSelection = item }
    }

    private var flatFolders: [(node: FolderNode, depth: Int)] {
        var out: [(FolderNode, Int)] = []
        func walk(_ nodes: [FolderNode], _ depth: Int) {
            for n in nodes {
                out.append((n, depth))
                if !collapsed.contains(n.url) { walk(n.children ?? [], depth + 1) }
            }
        }
        walk(store.folders, 0)
        return out
    }

    private func folderRow(_ folder: FolderNode, depth: Int) -> some View {
        row(icon: "folder", title: folder.name, count: store.noteCount(in: folder.url), item: .folder(folder.url),
            depth: depth, hasChildren: !(folder.children ?? []).isEmpty, url: folder.url)
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

/// Tags as chips that wrap across lines.
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
                    .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(selected ? theme.accent.opacity(0.32) : Color.primary.opacity(0.07), in: Capsule())
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
    static let folioFocusSearch = Notification.Name("folio.focusSearch")
}

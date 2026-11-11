import AppKit
import SwiftUI
import FolioCore

/// Note list as rounded cards grouped by date, with a header that carries the "new note" button.
struct NoteListView: View {
    @Binding var sidebarVisible: Bool
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var windowState: WindowState
    @FocusState private var focused: Bool
    @State private var showFilters = false
    @State private var savingView = false
    @State private var viewName = ""
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let notes = store.filteredNotes
        VStack(spacing: 0) {
            header(count: notes.count)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        // One flat list of headers and notes: a note that moves to another group (e.g. „Heute“
                        // after an edit) keeps its identity instead of being removed and inserted, which left a
                        // second, stale selected card behind (#128).
                        ForEach(rows(notes)) { row in
                            switch row {
                            case .header(let title):
                                Text(title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                            case .note(let note):
                                NoteCard(note: note, selected: store.selectedNoteID == note.id, showFolder: !isFolderSelected,
                                         favorite: store.isFavorite(note.id))
                                    .id(note.id)
                                    .onTapGesture {
                                        // ⌘-click opens the note in a new tab, ⌥-click on the right.
                                        let mods = NSEvent.modifierFlags
                                        if mods.contains(.command) { store.openInNewTab(note.id) }
                                        else if mods.contains(.option) { store.openInSplit(note.id) }
                                        else { store.selectedNoteID = note.id }
                                        focused = true
                                    }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(store.selectedNoteID == note.id ? [.isButton, .isSelected] : .isButton)
                                    .accessibilityAction { store.selectedNoteID = note.id }
                                    .accessibilityAction(named: "In neuem Tab öffnen") { store.openInNewTab(note.id) }
                                    .accessibilityAction(named: "Rechts daneben öffnen") { store.openInSplit(note.id) }
                                    .draggable(note.id.uuidString)
                                    // Dropping a note on another one puts it in front of it: the list keeps its own order (#13).
                                    .dropDestination(for: String.self) { items, _ in drop(items, on: note, in: notes) }
                                    .contextMenu { menu(for: note) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 16)
                    .animation(Motion.standard, value: notes.map(\.id))
                }
                .scrollIndicators(.never)
                .focusable()
                .focusEffectDisabled()
                .focused($focused)
                .onKeyPress(.downArrow) { step(1, in: notes, proxy: proxy); return .handled }
                .onKeyPress(.upArrow) { step(-1, in: notes, proxy: proxy); return .handled }
                .onDeleteCommand { if let id = store.selectedNoteID { store.delete(id) } }
            }
        }
        .overlay { if notes.isEmpty { emptyState } }
    }

    private var emptyState: some View {
        let searching = !store.searchText.isEmpty
        return VStack(spacing: 8) {
            Image(systemName: searching ? "magnifyingglass" : emptyIcon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(searching ? "Keine Treffer" : emptyTitle).font(.headline)
            Text(searching ? "Für „\(store.searchText)“ wurde nichts gefunden." : emptyHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    /// A note dropped on another one goes in front of it.
    private func drop(_ items: [String], on note: NoteRef, in notes: [NoteRef]) -> Bool {
        guard store.canReorderNotes, let id = items.first.flatMap(UUID.init(uuidString:)),
              id != note.id, notes.contains(where: { $0.id == id }) else { return false }
        withAnimation(Motion.standard) { store.moveNote(id, before: note.id) }
        return true
    }

    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !sidebarVisible { WindowControls(window: windowState.window) }
            headerRow(count: count)
            listTools
            FilterChips()
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .alert("Intelligente Ansicht sichern", isPresented: $savingView) {
            TextField("Name", text: $viewName)
            Button("Sichern") { store.saveSearchAsSmartView(named: viewName) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Ansicht erscheint in der Seitenleiste und zeigt immer die Notizen, die zu „\(SmartView(name: "", filter: store.activeSearch).summary)“ passen.")
        }
    }

    private func headerRow(count: Int) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if !sidebarVisible {
                iconButton("sidebar.left", help: "Seitenleiste einblenden") { sidebarVisible = true }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 20, weight: .bold, design: .rounded)).lineLimit(1)
                Text(subtitle(count)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if sidebarVisible {
                iconButton("sidebar.left", help: "Seitenleiste ausblenden") { sidebarVisible = false }
            }
            filterButton
            if store.sidebarSelection == .templates {
                iconButton("plus", help: "Neue Vorlage", prominent: true) { store.createTemplate() }
            } else {
                Menu {
                    Button("Leere Notiz") { store.createNote(initialTag: currentTag) }
                    Section("Aus Vorlage") {
                        ForEach(store.templates, id: \.id) { t in Button(t.meta.title) { store.createNote(from: t) } }
                        Button("Vorlagen verwalten …") { store.ensureStarterTemplates(); store.sidebarSelection = .templates }
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(theme.accent)
                } primaryAction: {
                    store.createNote(initialTag: currentTag)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .helpLabel("Neue Notiz (⌘N) – gedrückt halten: aus Vorlage")
                .onAppear { store.ensureStarterTemplates() }
            }
        }
    }

    /// Search filters; sorting and saving the search sit in their own slim row below the title.
    private var filterButton: some View {
        iconButton(store.searchFilter.hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                   help: "Suchfilter: Tag, Ordner, Zeitraum, Inhalt") { showFilters.toggle() }
            .popover(isPresented: $showFilters, arrowEdge: .bottom) { SearchFilterPopover().environmentObject(store) }
    }

    /// Order of the list (#13) and „save this search as a view“ (#14).
    @ViewBuilder private var listTools: some View {
        if store.sidebarSelection != .templates {
            HStack(spacing: 8) {
                if store.sidebarSelection != .favorites { sortMenu }
                Spacer(minLength: 4)
                if store.isSearching {
                    Button {
                        viewName = store.activeSearch.text
                        savingView = true
                    } label: {
                        Label("Als Ansicht sichern", systemImage: "plus.magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                    .helpLabel("Suche als intelligente Ansicht in der Seitenleiste sichern")
                }
            }
            .font(.system(size: 11.5, weight: .medium))
        }
    }

    /// Dragging a note also switches to the own order.
    private var sortMenu: some View {
        Menu {
            Picker("Sortieren nach", selection: Binding(get: { store.organization.sortMode },
                                                        set: { store.organization.sortMode = $0 })) {
                ForEach(NoteSortMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            if store.organization.sortMode == .manual {
                Divider()
                Text("Notizen in der Liste ziehen, um sie anzuordnen")
            }
        } label: {
            Label(store.organization.sortMode.label, systemImage: "arrow.up.arrow.down")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .helpLabel("Sortieren: \(store.organization.sortMode.label)")
    }

    private var emptyIcon: String {
        switch store.sidebarSelection {
        case .favorites: return "star"
        case .smartView: return "sparkle.magnifyingglass"
        default: return "note.text"
        }
    }

    private var emptyTitle: String {
        switch store.sidebarSelection {
        case .favorites: return "Keine Favoriten"
        case .smartView(let id): return store.smartView(id) == nil ? "Ansicht nicht gefunden" : "Keine passenden Notizen"
        default: return "Keine Notizen"
        }
    }

    private var emptyHint: String {
        switch store.sidebarSelection {
        case .favorites: return "Über das Kontextmenü einer Notiz oder den Stern in der Notiz fügst du Favoriten hinzu."
        case .smartView(let id):
            return store.smartView(id).map { "Sobald Notizen zu „\($0.summary)“ passen, erscheinen sie hier." } ?? "Diese Ansicht wurde gelöscht."
        default: return "Mit ⌘N legst du eine neue an."
        }
    }

    private func iconButton(_ icon: String, help: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 34)
                .background(prominent ? theme.accent.opacity(0.18) : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(prominent ? theme.accent : .primary)
        }
        .buttonStyle(.plain)
        .helpLabel(help)
    }

    private func step(_ delta: Int, in notes: [NoteRef], proxy: ScrollViewProxy) {
        guard !notes.isEmpty else { return }
        let i = store.selectedNoteID.flatMap { id in notes.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : notes.count)
        let j = min(max(i + delta, 0), notes.count - 1)
        store.selectedNoteID = notes[j].id
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(notes[j].id) }
    }

    private struct Group { var title: String; var notes: [NoteRef] }

    enum Row: Identifiable {
        case header(String)
        case note(NoteRef)
        var id: String {
            switch self {
            case .header(let t): return "header-" + t
            case .note(let n): return n.id.uuidString
            }
        }
    }

    private func rows(_ notes: [NoteRef]) -> [Row] {
        var seen = Set<UUID>()
        return groups(notes).flatMap { g in
            // A note is listed once, even if two files share an id.
            [Row.header(g.title)] + g.notes.filter { seen.insert($0.id).inserted }.map(Row.note)
        }
    }

    private func groups(_ notes: [NoteRef]) -> [Group] {
        if store.sidebarSelection == .favorites { return [Group(title: "Favoriten", notes: notes)] }
        let mode = store.organization.sortMode
        guard mode.groupsByDate else {
            let pinned = notes.filter(\.meta.pinned), rest = notes.filter { !$0.meta.pinned }
            return [Group(title: "Angepinnt", notes: pinned), Group(title: "Notizen", notes: rest)].filter { !$0.notes.isEmpty }
        }
        let cal = Calendar.current
        let now = Date()
        var buckets: [(String, [NoteRef])] = [("Angepinnt", []), ("Heute", []), ("Gestern", []), ("Letzte 7 Tage", []),
                                              ("Letzte 30 Tage", []), ("Älter", [])]
        for n in notes {
            let d = mode == .created ? n.meta.created : n.meta.modified
            let idx: Int
            if n.meta.pinned { idx = 0 }
            else if cal.isDateInToday(d) { idx = 1 }
            else if cal.isDateInYesterday(d) { idx = 2 }
            else if let days = cal.dateComponents([.day], from: d, to: now).day, days < 7 { idx = 3 }
            else if let days = cal.dateComponents([.day], from: d, to: now).day, days < 30 { idx = 4 }
            else { idx = 5 }
            buckets[idx].1.append(n)
        }
        return buckets.filter { !$0.1.isEmpty }.map { Group(title: $0.0, notes: $0.1) }
    }

    private var isFolderSelected: Bool {
        if case .folder = store.sidebarSelection { return true }
        return false
    }

    private var currentTag: String? {
        if case .tag(let t) = store.sidebarSelection { return t }
        return nil
    }

    private var title: String {
        switch store.sidebarSelection ?? .all {
        case .all: return "Alle Notizen"
        case .pinned: return "Angepinnt"
        case .favorites: return "Favoriten"
        case .smartView(let id): return store.smartView(id)?.name ?? "Intelligente Ansicht"
        case .folder(let url): return url.lastPathComponent
        case .tag(let t): return "#\(t)"
        case .trash: return "Papierkorb"
        case .damaged: return "Beschädigte Notizen"
        case .templates: return "Vorlagen"
        case .graph: return "Graph"
        }
    }

    private func subtitle(_ count: Int) -> String {
        if store.sidebarSelection == .templates { return "\(count) Vorlage\(count == 1 ? "" : "n") · {{datum}} wird beim Anlegen ersetzt" }
        var s = "\(count) Notiz\(count == 1 ? "" : "en")"
        if case .smartView(let id) = store.sidebarSelection, let view = store.smartView(id), !store.isSearching {
            return s + " · " + view.summary
        }
        if store.isSearching {
            s += store.searchText.isEmpty ? " · gefiltert" : " · Suche „\(store.searchText)“"
            if store.searchEverywhere, store.sidebarSelection != .all { s += " in allen Notizen" }
        } else if case .folder = store.sidebarSelection, store.includeSubfolders {
            s += " · mit Unterordnern"
        }
        return s
    }

    /// Pin, favorite and place in the list (#13, #15).
    @ViewBuilder
    private func organizeMenu(for note: NoteRef) -> some View {
        Button(note.meta.pinned ? "Loslösen" : "Anpinnen") { store.togglePin(note.id) }
        Button(store.isFavorite(note.id) ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen") { store.toggleFavorite(note.id) }
        if store.canReorderNotes {
            Button("Nach oben") { withAnimation(Motion.standard) { store.stepNote(note.id, by: -1) } }
            Button("Nach unten") { withAnimation(Motion.standard) { store.stepNote(note.id, by: 1) } }
        }
    }

    @ViewBuilder
    private func menu(for note: NoteRef) -> some View {
        organizeMenu(for: note)
        Divider()
        Button("In neuem Tab öffnen") { store.openInNewTab(note.id) }
        Button("Rechts daneben öffnen") { store.openInSplit(note.id) }
        Button("In neuem Fenster öffnen") { openWindow(id: "note", value: note.id) }
        Button("Duplizieren") { store.duplicate(note.id) }
        if let current = store.currentDocument?.id, current != note.id {
            Button("Zum KI-Chat hinzufügen (Vergleich)") {
                AIChatModel.forNote(current).addNote(note.id)
                NotificationCenter.default.post(name: .folioOpenChat, object: nil)
            }
        }
        Divider()
        Button("Notizlink kopieren") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(NoteLink.url(for: note.id).absoluteString, forType: .string)
        }
        Menu("Bewegen nach") {
            ForEach(store.allFolderURLs, id: \.self) { url in
                Button(store.relativeFolderName(url)) { store.move(note.id, to: url) }
            }
        }
        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
        // Which note the „Notiz des Tages“ and „Checkliste“ widgets show (#81, #82).
        Menu("Im Widget zeigen") {
            let theme = ThemeManager.shared
            Button(theme.settings.widgetNote == note.id.uuidString ? "✓ Als Notiz des Tages" : "Als Notiz des Tages") {
                theme.settings.widgetNote = theme.settings.widgetNote == note.id.uuidString ? "" : note.id.uuidString
            }
            if note.meta.searchText.contains("☐") || note.meta.searchText.contains("☑") {
                Button(theme.settings.widgetChecklist == note.id.uuidString ? "✓ Als Checkliste" : "Als Checkliste") {
                    theme.settings.widgetChecklist = theme.settings.widgetChecklist == note.id.uuidString ? "" : note.id.uuidString
                }
            }
        }
        Divider()
        Button("In den Papierkorb legen", role: .destructive) { store.delete(note.id) }
    }
}

struct NoteCard: View {
    var note: NoteRef
    var selected: Bool
    var showFolder: Bool
    var favorite = false
    @EnvironmentObject var theme: ThemeManager
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            titleRow
            HStack(spacing: 0) {
                Text(dateString).foregroundStyle(.primary.opacity(0.75))
                Text(" · ").foregroundStyle(.secondary)
                Text(note.meta.preview.isEmpty ? "Kein zusätzlicher Text" : note.meta.preview)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.system(size: 12))
            if showFolder || !note.meta.tags.isEmpty {
                HStack(spacing: 6) {
                    if showFolder {
                        Label(note.folderURL.lastPathComponent, systemImage: "folder")
                            .foregroundStyle(.tertiary)
                    }
                    Text(note.meta.tags.prefix(4).map { "#\($0)" }.joined(separator: " "))
                        .foregroundStyle(theme.accent)
                        .lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Flat rows like in Apple Notes: only hover and selection get a background (#131).
        .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: selected)
        .animation(Motion.quick, value: hovering)
    }

    private var titleRow: some View {
        HStack(spacing: 5) {
            if note.meta.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(theme.accent)
            }
            if favorite {
                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                    .accessibilityLabel("Favorit")
            }
            Text(note.meta.title.isEmpty ? "Neue Notiz" : note.meta.title)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
        }
    }

    private var background: Color {
        if selected { return theme.accent.opacity(0.2) }
        return Color.primary.opacity(hovering ? 0.06 : 0)
    }

    private var dateString: String {
        let d = note.meta.modified
        if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(d) { return "Gestern" }
        if let days = Calendar.current.dateComponents([.day], from: d, to: Date()).day, days < 7 {
            return d.formatted(.dateTime.weekday(.wide))
        }
        return d.formatted(.dateTime.day().month(.twoDigits).year(.twoDigits))
    }
}

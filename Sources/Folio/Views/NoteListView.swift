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
                                NoteCard(note: note, selected: store.selectedNoteID == note.id, showFolder: !isFolderSelected)
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
        .overlay {
            if notes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: store.searchText.isEmpty ? "note.text" : "magnifyingglass")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(store.searchText.isEmpty ? "Keine Notizen" : "Keine Treffer").font(.headline)
                    Text(store.searchText.isEmpty ? "Mit ⌘N legst du eine neue an." : "Für „\(store.searchText)“ wurde nichts gefunden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
    }

    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !sidebarVisible { WindowControls(window: windowState.window) }
            headerRow(count: count)
            FilterChips()
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 8)
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
            iconButton(store.searchFilter.hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                       help: "Suchfilter: Tag, Ordner, Zeitraum, Inhalt") { showFilters.toggle() }
                .popover(isPresented: $showFilters, arrowEdge: .bottom) { SearchFilterPopover().environmentObject(store) }
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
        let cal = Calendar.current
        let now = Date()
        var buckets: [(String, [NoteRef])] = [("Angepinnt", []), ("Heute", []), ("Gestern", []), ("Letzte 7 Tage", []),
                                              ("Letzte 30 Tage", []), ("Älter", [])]
        for n in notes {
            let d = n.meta.modified
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
        if store.isSearching {
            s += store.searchText.isEmpty ? " · gefiltert" : " · Suche „\(store.searchText)“"
            if store.searchEverywhere, store.sidebarSelection != .all { s += " in allen Notizen" }
        } else if case .folder = store.sidebarSelection, store.includeSubfolders {
            s += " · mit Unterordnern"
        }
        return s
    }

    @ViewBuilder
    private func menu(for note: NoteRef) -> some View {
        Button(note.meta.pinned ? "Loslösen" : "Anpinnen") { store.togglePin(note.id) }
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
    @EnvironmentObject var theme: ThemeManager
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if note.meta.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(theme.accent)
                }
                Text(note.meta.title.isEmpty ? "Neue Notiz" : note.meta.title)
                    .font(.system(size: 13.5, weight: selected ? .bold : .semibold))
                    .lineLimit(1)
            }
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
        .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? theme.accent.opacity(0.5) : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: selected)
        .animation(Motion.quick, value: hovering)
    }

    private var background: Color {
        if selected { return theme.accent.opacity(0.22) }
        return Color.primary.opacity(hovering ? 0.08 : 0.035)
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

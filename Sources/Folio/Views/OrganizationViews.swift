import AppKit
import SwiftUI
import FolioCore

// MARK: - Quick open & note links (#20, #7)

/// What the quick-open panel is used for.
enum QuickOpenMode: Equatable {
    /// ⌘P: jump to a note (recent ones first).
    case open
    /// Insert a link to the chosen note at the cursor.
    case link
    /// Add the chosen note to the open note's AI chat, for comparing (#34).
    case addToChat
    /// Embed the chosen note read-only (#120).
    case embed
}

/// Floating panel with fuzzy search over all notes; the recently opened ones come first.
struct QuickOpenView: View {
    var mode: QuickOpenMode
    var onClose: () -> Void
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    /// Notes (recent ones first) and, when opening, also folders and tags (#88).
    private var results: [SwitcherEntry] {
        let recentIDs = store.recent.ids
        let byID = Dictionary(store.notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let recent = recentIDs.compactMap { byID[$0] }
        let others = store.notes.filter { !recentIDs.contains($0.id) }.sorted { $0.meta.modified > $1.meta.modified }
        var notes = recent + others
        if mode != .open, let current = store.currentDocument?.id { notes.removeAll { $0.id == current } }
        var entries = notes.map { ref in
            SwitcherEntry(kind: .note, title: ref.meta.title.isEmpty ? ref.url.deletingPathExtension().lastPathComponent : ref.meta.title,
                          detail: store.relativeFolderName(ref.folderURL) + (ref.meta.preview.isEmpty ? "" : " · " + ref.meta.preview),
                          key: ref.id.uuidString)
        }
        if mode == .open {
            entries += store.allFolderURLs.map { url in
                SwitcherEntry(kind: .folder, title: url.lastPathComponent, detail: store.relativeFolderName(url), key: url.path)
            }
            entries += store.tagCounts.map { t in
                SwitcherEntry(kind: .tag, title: "#\(t.tag)", detail: "\(t.count) Notiz\(t.count == 1 ? "" : "en")", key: t.tag)
            }
            // Without a query only notes are listed; folders and tags come with typing (or "/" and "#").
            if query.isEmpty { entries = entries.filter { $0.kind == .note } }
        }
        return Array(SwitcherEntry.rank(entries, query: query).prefix(50))
    }

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: mode == .link ? "link" : mode == .addToChat ? "sparkles" : "magnifyingglass").foregroundStyle(.secondary)
                TextField(mode == .link ? "Notiz zum Verlinken suchen …" : mode == .addToChat ? "Notiz zum Vergleichen hinzufügen …" : mode == .embed ? "Notiz zum Einbetten suchen …" : "Notiz, Ordner (/) oder Tag (#) öffnen …", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { items.isEmpty ? linkNewNote() : choose(items) }
                    .onKeyPress(.downArrow) { index = min(index + 1, max(items.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                    .onKeyPress(.escape) { onClose(); return .handled }
                    .accessibilityLabel("Suche")
                Text(mode == .link ? "↩ verlinken" : mode == .addToChat ? "↩ hinzufügen" : mode == .embed ? "↩ einbetten" : "↩ öffnen").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
            Divider()
            if mode == .link, !query.trimmingCharacters(in: .whitespaces).isEmpty,
               store.linkIndex.resolve(query) == nil {
                // [[Titel]] to a note that does not exist yet; clicking it later creates the note (#115).
                Button { linkNewNote() } label: {
                    Label("„\(query.trimmingCharacters(in: .whitespaces))“ als neue Notiz verlinken", systemImage: "link.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .helpLabel(items.isEmpty ? "↩" : "Fügt [[\(query)]] ein; ein Klick darauf legt die Notiz an")
            }
            if items.isEmpty {
                Text(store.notes.isEmpty ? "Noch keine Notizen." : "Nichts passt zu „\(query)“.")
                    .foregroundStyle(.secondary).padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            if query.isEmpty, !store.recent.ids.isEmpty {
                                Text("Zuletzt geöffnet").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 4)
                            }
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, entry in
                                row(entry, selected: i == index)
                                    .id(entry.id)
                                    .onTapGesture { index = i; choose(items) }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(i == index ? [.isButton, .isSelected] : .isButton)
                                    .accessibilityAction { index = i; choose(items) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: index) { if items.indices.contains(index) { proxy.scrollTo(items[index].id) } }
                }
            }
        }
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        .onAppear {
            // The editor and the sidebar search are AppKit first responders that SwiftUI focus does not
            // take over by itself, so typing went into the note behind (#99): release them first.
            (NSApp.mainWindow ?? NSApp.keyWindow)?.makeFirstResponder(nil)
            focused = true
            DispatchQueue.main.async {
                focused = true
                DispatchQueue.main.async {
                    if let field = (NSApp.mainWindow ?? NSApp.keyWindow)?.firstResponder as? NSTextView, field.isFieldEditor {
                        FormattingController.shared.releaseHeldTyping(into: field)
                    }
                }
            }
        }
        .onChange(of: query) { index = 0 }
    }

    private func row(_ entry: SwitcherEntry, selected: Bool) -> some View {
        let icon: String
        switch entry.kind {
        case .note: icon = UUID(uuidString: entry.key).map { store.recent.ids.contains($0) } == true ? "clock" : "note.text"
        case .folder: icon = "folder"
        case .tag: icon = "number"
        }
        return HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(selected ? theme.accent : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title.isEmpty ? "Ohne Titel" : entry.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? theme.accent.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
    }

    private func choose(_ items: [SwitcherEntry]) {
        guard items.indices.contains(index) else { return }
        let entry = items[index]
        onClose()
        switch entry.kind {
        case .folder:
            store.searchText = ""
            store.sidebarSelection = .folder(URL(fileURLWithPath: entry.key, isDirectory: true))
            return
        case .tag:
            store.searchText = ""
            store.sidebarSelection = .tag(entry.key)
            return
        case .note: break
        }
        guard let id = UUID(uuidString: entry.key), let ref = store.notes.first(where: { $0.id == id }) else { return }
        switch mode {
        case .open:
            store.open(noteID: ref.id)
        case .link:
            NoteLinkInserter.insert(ref)
        case .addToChat:
            if let current = store.currentDocument?.id { AIChatModel.forNote(current).addNote(ref.id) }
        case .embed:
            NotificationCenter.default.post(name: .folioInsert, object: "embed:" + ref.meta.title)
        }
    }

    /// Inserts `[[query]]` at the cursor, as text that becomes a link (#115).
    private func linkNewNote() {
        let title = query.trimmingCharacters(in: .whitespaces)
        guard mode == .link, !title.isEmpty else { return }
        onClose()
        guard let tv = FormattingController.shared.activeTextView, tv.window != nil else { return }
        let text = "[[\(title)]] "
        let range = tv.selectedRange()
        tv.window?.makeFirstResponder(tv)
        if tv.shouldChangeText(in: range, replacementString: text) {
            tv.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: tv.typingAttributes))
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        }
    }
}

@MainActor
enum NoteLinkInserter {
    /// Inserts the note's title as a link (folio://note/<id>) at the cursor of the focused text block.
    static func insert(_ ref: NoteRef) {
        let f = FormattingController.shared
        let doc = NoteStore.shared.currentDocument
        guard let tv = f.activeTextView, tv.window != nil, let blockID = tv.blockID, doc?.block(blockID) != nil else {
            // No text cursor in this note (nothing focused, or the cursor is in a code block):
            // the link goes on a new line at the end of the note instead of getting lost.
            appendAtEnd(ref, in: doc)
            return
        }
        var attrs = tv.typingAttributes
        attrs[.link] = NoteLink.url(for: ref.id)
        let title = ref.meta.title.isEmpty ? "Notiz" : ref.meta.title
        let s = NSMutableAttributedString(string: title, attributes: attrs)
        var plain = tv.typingAttributes
        plain[.link] = nil
        s.append(NSAttributedString(string: " ", attributes: plain))
        let range = tv.selectedRange()
        tv.window?.makeFirstResponder(tv)
        if tv.shouldChangeText(in: range, replacementString: s.string) {
            tv.textStorage?.replaceCharacters(in: range, with: s)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: range.location + s.length, length: 0))
            tv.typingAttributes = plain
        }
    }
}

extension NoteLinkInserter {
    static func appendAtEnd(_ ref: NoteRef, in doc: NoteDocument?) {
        guard let doc else { return }
        let body = ThemeManager.shared.bodyAttributes
        let block: BlockModel
        if let last = doc.blocks.last(where: { $0.kind == .text }) { block = last } else {
            block = .text()
            doc.blocks.append(block)
        }
        var linkAttrs = body
        linkAttrs[.link] = NoteLink.url(for: ref.id)
        let s = NSMutableAttributedString()
        if block.storage.length > 0 { s.append(NSAttributedString(string: "\n", attributes: body)) }
        s.append(NSAttributedString(string: ref.meta.title.isEmpty ? "Notiz" : ref.meta.title, attributes: linkAttrs))
        if let tv = FormattingController.shared.textView(for: block.id), tv.textStorage === block.storage, tv.shouldChangeText(in: NSRange(location: block.storage.length, length: 0), replacementString: s.string) {
            tv.textStorage?.append(s)
            tv.didChangeText()
        } else {
            block.storage.append(s)
            block.revision += 1
        }
        doc.markDirty()
        FormattingController.shared.focus(blockID: block.id)
    }
}

// MARK: - Backlinks (#7)

/// "Verweise auf diese Notiz": notes that link here, at the end of the editor.
/// Below the note: notes linking here, notes mentioning this title without a link (#112), and the
/// local graph (#111).
struct BacklinksView: View {
    var noteID: UUID
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager
    @AppStorage("folio.showLocalGraph") private var showGraph = false
    @AppStorage("folio.localGraphDepth") private var depth = 1
    @State private var showMentions = false

    var body: some View {
        let backlinks = store.linkIndex.backlinks(noteID).compactMap { id in store.notes.first { $0.id == id } }
            .sorted { $0.meta.modified > $1.meta.modified }
        let mentions = showMentions ? store.unlinkedMentions(of: noteID) : []
        let unresolved = store.linkIndex.unresolved(noteID)
        VStack(alignment: .leading, spacing: 10) {
            if !backlinks.isEmpty {
                Label("\(backlinks.count) Verweis\(backlinks.count == 1 ? "" : "e") auf diese Notiz", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(backlinks, id: \.id) { ref in chip(ref) }
                }
            }
            if !unresolved.isEmpty {
                Label("Verlinkt, aber noch nicht angelegt", systemImage: "link.badge.plus")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(unresolved, id: \.self) { key in
                        // The title as written (the index keeps only the folded key).
                        let title = store.notes.first { $0.id == noteID }.flatMap { WikiLink.targets(in: $0.meta.searchText).first { WikiLink.key($0) == key } } ?? key
                        Button { store.openOrCreate(title: title) } label: {
                            Label(title, systemImage: "plus").font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .overlay(Capsule().strokeBorder(theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        }
                        .buttonStyle(.plain)
                        .helpLabel("Notiz „\(title)“ anlegen")
                    }
                }
            }
            HStack(spacing: 14) {
                Button("Eigenschaft hinzufügen") { NotificationCenter.default.post(name: .folioAddProperty, object: noteID) }
                    .helpLabel("Status, Datum, Zahl, Ja/Nein oder Text zu dieser Notiz (#121)")
                Button(showMentions ? "Erwähnungen ausblenden" : "Unverlinkte Erwähnungen suchen") { showMentions.toggle() }
                Button(showGraph ? "Lokalen Graph ausblenden" : "Lokalen Graph zeigen") { withAnimation(Motion.quick) { showGraph.toggle() } }
                if showGraph {
                    Picker("Tiefe", selection: $depth) {
                        Text("1 Schritt").tag(1)
                        Text("2 Schritte").tag(2)
                        Text("3 Schritte").tag(3)
                    }
                    .pickerStyle(.segmented).fixedSize().labelsHidden()
                    .helpLabel("Wie viele Verknüpfungen weit der lokale Graph reicht")
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            if showMentions {
                if mentions.isEmpty {
                    Text("Keine Notiz erwähnt diesen Titel ohne Link.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(mentions, id: \.id) { ref in
                        HStack {
                            chip(ref)
                            Text(snippet(ref)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button("Verlinken") { store.linkMention(in: ref.id, to: noteID) }
                                .buttonStyle(.borderless)
                                .helpLabel("Erwähnung in „\(ref.meta.title)“ in einen [[Link]] umwandeln")
                        }
                    }
                }
            }
            if showGraph {
                GraphView(focus: noteID, depth: depth, compact: true)
                    .frame(height: 260)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .padding(.leading, BlockRow.gutter)
    }

    private func chip(_ ref: NoteRef) -> some View {
        Button { store.open(noteID: ref.id) } label: {
            Label(ref.meta.title.isEmpty ? "Ohne Titel" : ref.meta.title, systemImage: "note.text")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(theme.accent.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .helpLabel("Öffnen")
    }

    private func snippet(_ ref: NoteRef) -> String {
        guard let title = store.notes.first(where: { $0.id == noteID })?.meta.title,
              let r = Mentions.ranges(of: title, in: ref.meta.searchText).first else { return "" }
        let ns = ref.meta.searchText as NSString
        let start = max(0, r.location - 30)
        return "…" + ns.substring(with: NSRange(location: start, length: min(ns.length - start, r.length + 60))).replacingOccurrences(of: "\n", with: " ") + "…"
    }
}

// MARK: - Search filters (#8, #17)

struct SearchFilterPopover: View {
    @EnvironmentObject var store: NoteStore

    var body: some View {
        Form {
            Section("Suche") {
                Toggle("In der ganzen Bibliothek suchen", isOn: $store.searchEverywhere)
                Toggle("Ordner mit Unterordnern anzeigen", isOn: $store.includeSubfolders)
            }
            Section("Filter") {
                Picker("Geändert", selection: $store.searchFilter.period) {
                    ForEach(SearchFilter.Period.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Ordner", selection: $store.searchFilter.folder) {
                    Text("Alle").tag(String?.none)
                    ForEach(store.allFolderURLs, id: \.self) { url in
                        Text(store.relativeFolderName(url)).tag(Optional(store.relativeFolderName(url)))
                    }
                }
                Menu(store.searchFilter.tags.isEmpty ? "Alle Tags" : store.searchFilter.tags.sorted().map { "#\($0)" }.joined(separator: " ")) {
                    ForEach(store.tagCounts, id: \.tag) { t in
                        Toggle("#\(t.tag) (\(t.count))", isOn: binding(tag: t.tag))
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Enthält")
                    FlowLayout(spacing: 6) {
                        ForEach(SearchFilter.contentTypes, id: \.id) { t in
                            let on = store.searchFilter.types.contains(t.id)
                            Button(t.label) {
                                if on { store.searchFilter.types.remove(t.id) } else { store.searchFilter.types.insert(t.id) }
                            }
                            .buttonStyle(.bordered)
                            .tint(on ? .accentColor : nil)
                            .controlSize(.small)
                        }
                    }
                }
            }
            Section {
                Button("Filter zurücksetzen") { store.searchFilter = SearchFilter() }
                    .disabled(!store.searchFilter.hasFilters)
            } footer: {
                Text("Auch tippbar: tag:rezept, ordner:Projekte, typ:code, seit:7").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 470)
    }

    private func binding(tag: String) -> Binding<Bool> {
        Binding(get: { store.searchFilter.tags.contains(tag) },
                set: { on in if on { store.searchFilter.tags.insert(tag) } else { store.searchFilter.tags.remove(tag) } })
    }
}

/// Active filters as removable chips under the note list header.
struct FilterChips: View {
    @EnvironmentObject var store: NoteStore

    var body: some View {
        let f = store.searchFilter
        if f.hasFilters {
            FlowLayout(spacing: 5) {
                if f.period != .any { chip(f.period.label) { store.searchFilter.period = .any } }
                if let folder = f.folder { chip("Ordner: \(folder)") { store.searchFilter.folder = nil } }
                ForEach(f.tags.sorted(), id: \.self) { t in chip("#\(t)") { store.searchFilter.tags.remove(t) } }
                ForEach(f.types.sorted(), id: \.self) { t in
                    chip(SearchFilter.contentTypes.first { $0.id == t }?.label ?? t) { store.searchFilter.types.remove(t) }
                }
            }
        }
    }

    private func chip(_ text: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Text(text)
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Filter entfernen")
    }
}

// MARK: - Tags (#18)

struct TagEditSheet: View {
    enum Action { case rename, merge, remove }
    var tag: String
    var action: Action
    @EnvironmentObject var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var target = ""
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(heading).font(.title3.weight(.semibold))
            let count = store.notes.filter { $0.meta.tags.contains { $0 == tag || $0.hasPrefix(tag + "/") } }.count
            Text("Betrifft \(count) Notiz\(count == 1 ? "" : "en")\(store.tagCounts.contains { $0.tag.hasPrefix(tag + "/") } ? " (mit Untertags wie #\(tag)/…)" : ""). Vor jeder Änderung wird eine Version gesichert.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !started {
                switch action {
                case .rename:
                    TextField("Neuer Name", text: $newName).textFieldStyle(.roundedBorder)
                    if let n = TagEdit.normalized(newName), store.tagCounts.contains(where: { $0.tag == n }), n != tag {
                        Label("#\(n) gibt es schon: Die Tags werden zusammengeführt.", systemImage: "arrow.triangle.merge").foregroundStyle(.orange)
                    } else if !newName.isEmpty, TagEdit.normalized(newName) == nil {
                        Label("Ein Tag beginnt mit einem Buchstaben und enthält keine Satzzeichen.", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                case .merge:
                    Picker("Zusammenführen mit", selection: $target) {
                        ForEach(store.tagCounts.filter { $0.tag != tag }, id: \.tag) { Text("#\($0.tag)").tag($0.tag) }
                    }
                case .remove:
                    Text("Das Wort #\(tag) wird aus allen Notizen entfernt; der übrige Text bleibt.").foregroundStyle(.secondary)
                }
            }
            if let p = store.tagEdit, started {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1))) {
                    Text(p.finished ? "Fertig: \(p.changed) Notiz\(p.changed == 1 ? "" : "en") geändert." : "Ändere \(p.done) von \(p.total) …")
                }
                if !p.failures.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("\(p.failures.count) Notiz(en) konnten nicht geändert werden:", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        ForEach(p.failures, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    }
                }
            }
            HStack {
                Spacer()
                if store.tagEdit?.finished == true && started {
                    Button("Fertig") { store.tagEdit = nil; dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction).disabled(started)
                    Button(buttonTitle, role: action == .remove ? .destructive : nil) { run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(started || resultingTag == .invalid)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            newName = tag
            target = store.tagCounts.first { $0.tag != tag }?.tag ?? ""
        }
        .interactiveDismissDisabled(started && store.tagEdit?.finished != true)
    }

    private enum Resulting: Equatable { case invalid, tag(String?) }

    private var resultingTag: Resulting {
        switch action {
        case .rename:
            guard let n = TagEdit.normalized(newName), n != tag else { return .invalid }
            return .tag(n)
        case .merge: return target.isEmpty ? .invalid : .tag(target)
        case .remove: return .tag(nil)
        }
    }

    private var heading: String {
        switch action {
        case .rename: return "#\(tag) umbenennen"
        case .merge: return "#\(tag) zusammenführen"
        case .remove: return "#\(tag) aus allen Notizen entfernen"
        }
    }

    private var buttonTitle: String {
        switch action {
        case .rename: return "Umbenennen"
        case .merge: return "Zusammenführen"
        case .remove: return "Entfernen"
        }
    }

    private func run() {
        guard case .tag(let new) = resultingTag else { return }
        started = true
        Task { await store.editTag(tag, to: new) }
    }
}

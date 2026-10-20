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

    private var results: [NoteRef] {
        let recentIDs = store.recent.ids
        let byID = Dictionary(store.notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let recent = recentIDs.compactMap { byID[$0] }
        let others = store.notes.filter { !recentIDs.contains($0.id) }.sorted { $0.meta.modified > $1.meta.modified }
        var list = recent + others
        if mode == .link, let current = store.currentDocument?.id { list.removeAll { $0.id == current } }
        let ranked = FuzzyMatch.rank(list, query: query) { $0.meta.title.isEmpty ? $0.url.deletingPathExtension().lastPathComponent : $0.meta.title }
        return Array(ranked.prefix(50))
    }

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: mode == .link ? "link" : "magnifyingglass").foregroundStyle(.secondary)
                TextField(mode == .link ? "Notiz zum Verlinken suchen …" : "Notiz öffnen …", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { choose(items) }
                    .onKeyPress(.downArrow) { index = min(index + 1, max(items.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                    .onKeyPress(.escape) { onClose(); return .handled }
                Text(mode == .link ? "↩ verlinken" : "↩ öffnen").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
            Divider()
            if items.isEmpty {
                Text(store.notes.isEmpty ? "Noch keine Notizen." : "Keine Notiz passt zu „\(query)“.")
                    .foregroundStyle(.secondary).padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            if query.isEmpty, !store.recent.ids.isEmpty {
                                Text("Zuletzt geöffnet").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 4)
                            }
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, ref in
                                row(ref, selected: i == index)
                                    .id(ref.id)
                                    .onTapGesture { index = i; choose(items) }
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
        .onAppear { focused = true }
        .onChange(of: query) { index = 0 }
    }

    private func row(_ ref: NoteRef, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: store.recent.ids.contains(ref.id) ? "clock" : "note.text")
                .foregroundStyle(selected ? theme.accent : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(ref.meta.title.isEmpty ? "Ohne Titel" : ref.meta.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                Text(store.relativeFolderName(ref.folderURL) + (ref.meta.preview.isEmpty ? "" : " · " + ref.meta.preview))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? theme.accent.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
    }

    private func choose(_ items: [NoteRef]) {
        guard items.indices.contains(index) else { return }
        let ref = items[index]
        onClose()
        switch mode {
        case .open:
            if !store.filteredNotes.contains(where: { $0.id == ref.id }) { store.sidebarSelection = .all; store.searchText = "" }
            store.selectedNoteID = ref.id
        case .link:
            NoteLinkInserter.insert(ref)
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
        if let tv = FormattingController.shared.textView(for: block.id), tv.shouldChangeText(in: NSRange(location: block.storage.length, length: 0), replacementString: s.string) {
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
struct BacklinksView: View {
    var noteID: UUID
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        let links = NoteLink.backlinks(to: noteID, in: store.notes.map(\.meta))
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(links.count) Verweis\(links.count == 1 ? "" : "e") auf diese Notiz", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(links, id: \.id) { meta in
                        Button { store.open(noteID: meta.id) } label: {
                            Label(meta.title.isEmpty ? "Ohne Titel" : meta.title, systemImage: "note.text")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(theme.accent.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Öffnen")
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .padding(.leading, BlockRow.gutter)
        }
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

import AppKit
import SwiftUI
import FolioCore

/// Readable plain text of a note file (for previews and comparisons).
@MainActor
enum NoteText {
    static func of(_ file: NoteFile) -> String {
        file.body.blocks.map { r -> String in
            let b = BlockModel(record: r)
            switch r.kind {
            case .text: return b.storage.string
            case .code: return "```\(b.language)\n\(b.storage.string)\n```"
            case .math: return "Formel: \(b.storage.string)"
            case .diagram: return "Diagramm:\n\(b.storage.string)"
            case .image, .pdf, .file, .audio, .drawing:
                let name = r.attachmentID.flatMap { id in file.attachments.first { $0.id == id }?.header.filename }
                return "[\(kindName(r.kind))\(name.map { ": \($0)" } ?? "")]" + (r.output.map { "\n\($0)" } ?? "")
            case .web: return "[Webseite: \(r.url ?? "")]"
            case .database: return "```sql\n\(b.storage.string)\n```"
            case .embed: return "![[\(b.storage.string)]]"
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func kindName(_ kind: BlockKind) -> String {
        switch kind {
        case .image: return "Bild"
        case .pdf: return "PDF"
        case .file: return "Datei"
        case .audio: return "Audio"
        case .drawing: return "Zeichnung"
        default: return kind.rawValue
        }
    }
}

/// Lines of a comparison, colored like a diff.
struct DiffView: View {
    var lines: [TextDiff.Line]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 6) {
                        Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        Text(line.text.isEmpty ? " " : line.text)
                            .strikethrough(line.kind == .removed, color: .red.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(line.kind == .added ? Color.green.opacity(0.14) : line.kind == .removed ? Color.red.opacity(0.12) : .clear)
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Version history (#1)

struct VersionHistorySheet: View {
    @ObservedObject var doc: NoteDocument
    @EnvironmentObject var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [NoteVersion] = []
    @State private var selected: NoteVersion?
    @State private var preview: String = ""
    @State private var compare = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Versionsverlauf").font(.title3.weight(.semibold))
                    Text("Folio sichert beim Bearbeiten alle paar Minuten eine Version und immer, bevor etwas die Notiz ersetzt.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            if versions.isEmpty {
                ContentUnavailableView("Noch keine Versionen", systemImage: "clock.arrow.circlepath",
                                       description: Text("Sobald du die Notiz bearbeitest, erscheinen hier ältere Stände."))
                    .frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(versions, selection: $selected) { v in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 13, weight: .medium))
                            Text("\(v.date.formatted(.relative(presentation: .named))) · \(ByteCountFormatter.string(fromByteCount: v.size, countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(v)
                    }
                    .frame(width: 230)
                    Divider()
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Toggle("Mit aktuellem Stand vergleichen", isOn: $compare).toggleStyle(.switch).controlSize(.small)
                            Spacer()
                        }
                        .padding(10)
                        Divider()
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding()
                            Spacer()
                        } else if compare {
                            DiffView(lines: TextDiff.lines(NoteText.of(doc.makeFilePreview()), preview))
                        } else {
                            ScrollView {
                                Text(preview).font(.system(size: 13)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                if compare && error == nil && selected != nil {
                    Label("grün: in dieser Version, rot: nur im aktuellen Stand", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Als neue Notiz sichern") {
                    guard let v = selected, let file = try? store.history.read(v) else { return }
                    let stamp = v.date.formatted(date: .numeric, time: .shortened).replacingOccurrences(of: ":", with: ".")
                    if let ref = store.saveAsNewNote(file, in: doc.url.deletingLastPathComponent(), suffix: "(Version \(stamp))") {
                        dismiss()
                        store.selectedNoteID = ref.id
                    }
                }
                .disabled(selected == nil || error != nil)
                Button("Diese Version wiederherstellen") {
                    guard let v = selected else { return }
                    dismiss()
                    store.restoreVersion(v, of: doc)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected == nil || error != nil)
                .help("Der aktuelle Stand bleibt als Version erhalten.")
            }
            .padding(14)
        }
        .frame(width: 820, height: 560)
        .onAppear {
            doc.saveNow()
            versions = store.history.versions(of: doc.id)
            selected = versions.dropFirst().first ?? versions.first
        }
        .onChange(of: selected) { load() }
    }

    private func load() {
        guard let v = selected else { preview = ""; return }
        do {
            preview = NoteText.of(try store.history.read(v))
            error = nil
        } catch {
            self.error = "Diese Version ist beschädigt: \(error.localizedDescription)"
        }
    }
}

extension NoteDocument {
    /// The current content as a file, without touching title or modification date.
    func makeFilePreview() -> NoteFile {
        NoteFile(meta: meta, body: NoteBody(blocks: blocks.map { $0.record() }), attachments: Array(attachments.values))
    }
}

// MARK: - Conflicts (#53)

struct ConflictSheet: View {
    var conflict: NoteConflict
    @EnvironmentObject var store: NoteStore
    @State private var showDiff = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.system(size: 28)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("„\(conflict.doc.meta.title)“ wurde außerhalb von Folio geändert")
                        .font(.title3.weight(.semibold))
                    Text(conflict.diskData == nil
                         ? "Die Datei wurde gelöscht oder verschoben, während du sie bearbeitet hast."
                         : "Ein anderes Programm oder ein Sync-Dienst (z. B. iCloud) hat die Datei geändert, während du ungesicherte Änderungen hattest. Was nicht behalten wird, landet im Versionsverlauf.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let theirs = conflict.diskFile {
                DisclosureGroup("Unterschiede anzeigen", isExpanded: $showDiff) {
                    DiffView(lines: TextDiff.lines(NoteText.of(theirs), NoteText.of(conflict.doc.makeFilePreview())))
                        .frame(height: 260)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    Text("rot: nur in der geänderten Datei · grün: nur in deiner Version")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if conflict.diskData != nil {
                Label("Die geänderte Datei ist nicht lesbar; deine Version zu behalten ist sicher.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Beide behalten") { store.resolve(conflict, .keepBoth) }
                    .help("Deine Version wird als eigene Notiz „… (Konflikt)“ gesichert, die Notiz zeigt die geänderte Datei.")
                Spacer()
                if conflict.diskData != nil {
                    Button("Geänderte Datei übernehmen") { store.resolve(conflict, .takeTheirs) }
                        .help("Deine ungesicherten Änderungen bleiben im Versionsverlauf.")
                }
                Button("Meine Version behalten") { store.resolve(conflict, .keepMine) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .help("Überschreibt die geänderte Datei; sie bleibt im Versionsverlauf.")
            }
        }
        .padding(20)
        .frame(width: 640)
        .interactiveDismissDisabled()
    }
}

// MARK: - Trash (#2)

struct TrashView: View {
    @Binding var sidebarVisible: Bool
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var windowState: WindowState
    @State private var confirmEmpty = false
    @State private var confirmDelete: TrashItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if !sidebarVisible { WindowControls(window: windowState.window) }
                HStack {
                    if !sidebarVisible {
                        Button { sidebarVisible = true } label: { Image(systemName: "sidebar.left") }.buttonStyle(.borderless)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Papierkorb").font(.system(size: 22, weight: .bold, design: .rounded))
                        Text(retentionText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Papierkorb leeren …", role: .destructive) { confirmEmpty = true }
                        .disabled(store.trashItems.isEmpty)
                }
            }
            .padding(16)
            Divider()
            if store.trashItems.isEmpty {
                ContentUnavailableView("Der Papierkorb ist leer", systemImage: "trash",
                                       description: Text("Gelöschte Notizen und Ordner landen hier und lassen sich wiederherstellen."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.trashItems) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.isFolder ? "folder" : "note.text")
                            .font(.system(size: 18)).foregroundStyle(theme.accent).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                            Text(detail(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Wiederherstellen") { store.restore(item) }
                        Button(role: .destructive) { confirmDelete = item } label: { Image(systemName: "xmark.bin") }
                            .help("Endgültig löschen")
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button("Wiederherstellen") { store.restore(item) }
                        Button("Endgültig löschen …", role: .destructive) { confirmDelete = item }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .confirmationDialog("Papierkorb endgültig leeren?", isPresented: $confirmEmpty) {
            Button("\(store.trashItems.count) Objekte endgültig löschen", role: .destructive) { store.emptyTrash() }
        } message: {
            Text("Die Notizen und ihr Versionsverlauf werden gelöscht. Das lässt sich nicht rückgängig machen.")
        }
        .confirmationDialog("„\(confirmDelete?.title ?? "")“ endgültig löschen?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Endgültig löschen", role: .destructive) { if let item = confirmDelete { store.deletePermanently(item) } }
        } message: {
            Text("Auch der Versionsverlauf geht verloren. Das lässt sich nicht rückgängig machen.")
        }
    }

    private var retentionText: String {
        let days = theme.settings.trashRetentionDays
        return days > 0 ? "Objekte werden nach \(days) Tagen endgültig gelöscht." : "Objekte bleiben, bis du den Papierkorb leerst."
    }

    private func detail(_ item: TrashItem) -> String {
        var parts = ["Gelöscht \(item.deletedAt.formatted(.relative(presentation: .named)))"]
        let folder = (item.originalPath as NSString).deletingLastPathComponent
        parts.append("aus „\(folder.isEmpty ? "Bibliothek" : folder)“")
        if item.isFolder { parts.append("\(item.noteCount) Notiz\(item.noteCount == 1 ? "" : "en")") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Damaged notes (#54)

/// Shown instead of the editor when a note cannot be opened.
struct DamagedNoteView: View {
    var damaged: DamagedNote
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30)).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Diese Notiz ist beschädigt").font(.title2.weight(.semibold))
                        Text(damaged.url.lastPathComponent).foregroundStyle(.secondary)
                    }
                }
                DiagnosisDetails(report: damaged.report)
                actions
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var actions: some View {
        let version = store.latestIntactVersion(of: damaged)
        VStack(alignment: .leading, spacing: 10) {
            if let version {
                Button {
                    store.restoreLatestVersion(damaged)
                } label: {
                    Label("Letzte intakte Version wiederherstellen (\(version.date.formatted(date: .abbreviated, time: .shortened)))",
                          systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderedProminent)
            }
            if damaged.report.canSalvage {
                Button { store.salvage(damaged) } label: {
                    Label("Gerettete Inhalte als neue Notiz sichern", systemImage: "lifepreserver")
                }
                .buttonStyle(.bordered)
                .tint(version == nil ? .accentColor : nil)
            }
            HStack {
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([damaged.url]) }
                Button("Diagnose kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(DiagnosisDetails.text(damaged), forType: .string)
                }
            }
            Text("Die beschädigte Datei wird nie gelöscht: Beim Retten oder Wiederherstellen wird sie nach „.folio/damaged“ in der Bibliothek verschoben.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct DiagnosisDetails: View {
    var report: DiagnosticReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(report.problems, id: \.self) { p in
                Label(p.message, systemImage: p.severity == .error ? "xmark.octagon.fill" : p.severity == .warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(p.severity == .error ? Color.red : p.severity == .warning ? .orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Rettbar: \(rescued)").font(.callout).foregroundStyle(.secondary)
            if !report.blocks.isEmpty {
                let text = report.blocks.compactMap { b -> String? in
                    b.kind == .text ? BlockModel(record: b).storage.string : b.code
                }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    Text(String(text.prefix(1200)) + (text.count > 1200 ? " …" : ""))
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var rescued: String {
        var parts: [String] = []
        if let m = report.meta { parts.append("Titel „\(m.title)“") }
        parts.append("\(report.blocks.count) Blöcke" + (report.lostBlocks > 0 ? " (\(report.lostBlocks) verloren)" : ""))
        parts.append("\(report.attachments.count) Anhänge" + (report.lostAttachments > 0 ? " (\(report.lostAttachments) verloren)" : ""))
        return parts.joined(separator: " · ")
    }

    @MainActor static func text(_ d: DamagedNote) -> String {
        (["Folio-Diagnose: \(d.url.path) (\(d.report.fileSize) Byte)"] + d.report.problems.map { "- \($0.message)" }).joined(separator: "\n")
    }
}

/// Files in the library that cannot even be listed.
struct DamagedListView: View {
    @Binding var sidebarVisible: Bool
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var windowState: WindowState
    @State private var selected: URL?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    if !sidebarVisible { WindowControls(window: windowState.window) }
                    Text("Beschädigte Notizen").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Diese Dateien in der Bibliothek lassen sich nicht lesen.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                List(store.damagedNotes, selection: $selected) { d in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.url.deletingPathExtension().lastPathComponent).font(.system(size: 13, weight: .semibold))
                        Text(d.report.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .tag(d.url)
                }
                .scrollContentBackground(.hidden)
            }
            .frame(width: 300)
            Divider()
            if let d = store.damagedNotes.first(where: { $0.url == selected }) ?? store.damagedNotes.first {
                DamagedNoteView(damaged: d)
            } else {
                Spacer()
            }
        }
    }
}

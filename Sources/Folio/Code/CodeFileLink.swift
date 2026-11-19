import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FolioCore

/// Exporting a code block as a file and keeping it linked to that file (#28), with a diff view against it (#31).
@MainActor
enum CodeFileLink {
    /// Asks where to save the block's code, writes it and links the block to the file. Returns a status message.
    @discardableResult
    static func export(_ block: BlockModel, in doc: NoteDocument) -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = CodeExport.suggestedFileName(code: block.storage.string, language: block.language,
                                                                  caption: block.caption.isEmpty ? nil : block.caption)
        if let linked = block.linkedFile { panel.directoryURL = URL(fileURLWithPath: linked).deletingLastPathComponent() }
        panel.canCreateDirectories = true
        panel.message = "Der Code-Block bleibt mit der Datei verknüpft; Änderungen lassen sich später vergleichen."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return write(block, to: url, in: doc)
    }

    /// Writes the block to `url` (atomically) and links it. Returns a status message.
    @discardableResult
    static func write(_ block: BlockModel, to url: URL, in doc: NoteDocument) -> String {
        do {
            try CodeExport.write(code: block.storage.string, to: url)
            if block.linkedFile != url.path { doc.changeBlock(block, "Mit Datei verknüpfen") { block.linkedFile = url.path } }
            return "Gesichert: \(url.lastPathComponent)"
        } catch {
            return "Sichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    /// Replaces the block's code with the file's content (undoable).
    static func adopt(_ block: BlockModel, from url: URL, in doc: NoteDocument) -> String {
        guard let data = try? Data(contentsOf: url), data.count <= 5 << 20, let text = String(data: data, encoding: .utf8) else {
            return "Die Datei konnte nicht als Text gelesen werden."
        }
        var code = text.replacingOccurrences(of: "\r\n", with: "\n")
        if code.hasSuffix("\n") { code.removeLast() }
        doc.changeBlock(block, "Code aus Datei übernehmen") {
            block.storage.setAttributedString(NSAttributedString(string: code))
        }
        block.revision += 1
        return "Code aus \(url.lastPathComponent) übernommen."
    }
}

/// Small header chip: name of the linked file and whether it still matches the block.
struct CodeFileLinkChip: View {
    @ObservedObject var block: BlockModel
    var color: Color
    var onOpenDiff: () -> Void
    @State private var state: CodeExport.LinkState?

    var body: some View {
        if let path = block.linkedFile {
            Button(action: onOpenDiff) {
                HStack(spacing: 3) {
                    Image(systemName: symbol)
                    Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(state == .same || state == nil ? color : Color.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .frame(maxWidth: 180)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(help(path))
            .task(id: path) {
                // Cheap check (one file read, ≤ 5 MB) while the block is on screen.
                while !Task.isCancelled {
                    let code = block.storage.string
                    let url = URL(fileURLWithPath: path)
                    state = await Task.detached { CodeExport.compare(code: code, fileAt: url) }.value
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private var symbol: String {
        switch state {
        case .differs?: return "arrow.left.arrow.right.circle"
        case .missing?, .unreadable?: return "exclamationmark.triangle"
        default: return "doc.text"
        }
    }

    private func help(_ path: String) -> String {
        switch state {
        case .differs?: return "Verknüpft mit \(path)\nCode und Datei unterscheiden sich – klicken für den Vergleich."
        case .missing?: return "Verknüpfte Datei nicht gefunden: \(path)"
        case .unreadable(let why)?: return "Datei nicht lesbar (\(why)): \(path)"
        default: return "Verknüpft mit \(path) – gleicher Stand."
        }
    }
}

/// Side-by-side comparison of a code block with its linked file, as a unified diff (#31).
struct CodeDiffView: View {
    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument
    @Environment(\.dismiss) private var dismiss
    @State private var fileText: String?
    @State private var state: CodeExport.LinkState = .same
    @State private var message: String?

    private var url: URL? { block.linkedFile.map { URL(fileURLWithPath: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(14)
            Divider()
            content
            Divider()
            footer.padding(12)
        }
        .frame(minWidth: 640, minHeight: 420)
        .task { reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Vergleich mit verknüpfter Datei").font(.headline)
            if let url { Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
            if let fileText {
                let s = LineDiff.stats(LineDiff.diff(old: fileText, new: block.storage.string))
                Text("Datei → Code-Block: \(s.added) Zeilen hinzugefügt, \(s.removed) entfernt").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .missing:
            placeholder("Die Datei existiert nicht mehr. Mit „In Datei schreiben“ legst du sie neu an.")
        case .unreadable(let why):
            placeholder("Die Datei lässt sich nicht vergleichen: \(why).")
        case .same:
            placeholder("Code-Block und Datei sind gleich.")
        case .differs:
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(LineDiff.hunks(LineDiff.diff(old: fileText ?? "", new: block.storage.string)).enumerated()), id: \.offset) { _, hunk in
                        Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
                            .foregroundStyle(.purple).padding(.vertical, 2)
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in diffLine(line) }
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
            }
        }
    }

    private func diffLine(_ line: LineDiff.Line) -> some View {
        let (sign, color): (String, Color) = switch line.kind {
        case .added: ("+", .green)
        case .removed: ("-", .red)
        case .same: (" ", .clear)
        }
        return HStack(spacing: 6) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: 34, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.newNumber.map(String.init) ?? "").frame(width: 34, alignment: .trailing).foregroundStyle(.secondary)
            Text(sign + line.text).fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.14))
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
    }

    private var footer: some View {
        HStack {
            Button("Verknüpfung lösen") { doc.changeBlock(block, "Verknüpfung lösen") { block.linkedFile = nil }; dismiss() }
            Button("Diff kopieren") { copyDiff() }.disabled(state != .differs)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Button("Aus Datei übernehmen") { if let url { message = CodeFileLink.adopt(block, from: url, in: doc); reload() } }
                .disabled(state != .differs)
                .help("Ersetzt den Code des Blocks durch den Inhalt der Datei (rückgängig machbar)")
            Button("In Datei schreiben") { if let url { message = CodeFileLink.write(block, to: url, in: doc); reload() } }
                .disabled(state == .same || { if case .unreadable = state { return true }; return false }())
                .help("Überschreibt die Datei mit dem Code des Blocks")
            Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    private func reload() {
        guard let url else { state = .missing; return }
        state = CodeExport.compare(code: block.storage.string, fileAt: url)
        fileText = (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }?.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func copyDiff() {
        guard let url, let fileText else { return }
        let text = LineDiff.unified(old: fileText, new: block.storage.string, oldName: "a/" + url.lastPathComponent, newName: "b/" + url.lastPathComponent)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = "Diff kopiert."
    }
}

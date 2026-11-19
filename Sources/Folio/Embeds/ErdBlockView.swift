import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FolioCore

extension UTType {
    /// ERD-Ultra exports no type of its own; Folio imports one for `.erdu` (#204).
    static let erdu = UTType(importedAs: ErduDocument.typeIdentifier, conformingTo: .json)
}

/// Creating ER blocks and keeping them in step with their `.erdu` file (#204).
@MainActor
enum ErdBlocks {
    static func makeBlock(from url: URL) throws -> BlockModel {
        let data = try Data(contentsOf: url)
        let (text, _) = try ErduDocument.validate(data)
        let block = BlockModel(kind: .erd)
        block.storage.setAttributedString(NSAttributedString(string: text))
        block.mode = ErduDocument.View.er.rawValue
        block.caption = url.deletingPathExtension().lastPathComponent
        block.linkedFile = url.path
        return block
    }

    static func pickFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.erdu]
        panel.allowsOtherFileTypes = true
        panel.message = "ERD-Ultra-Projekt (.erdu) auswählen"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: ErduDocument.bundleIdentifier) }

    /// Takes in a changed file; returns nil when nothing changed, else a message (also for errors).
    static func pull(_ url: URL, into block: BlockModel, doc: NoteDocument) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let (text, _) = try ErduDocument.validate(data)
            guard text != block.storage.string else { return nil }
            doc.changeBlock(block, "ER-Diagramm aktualisieren") {
                block.storage.setAttributedString(NSAttributedString(string: text))
            }
            block.revision += 1
            return "Aktualisiert aus \(url.lastPathComponent) um \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            // A half-written or newer file never replaces the last good state.
            return "\(url.lastPathComponent): \(error.localizedDescription) Der letzte Stand bleibt sichtbar."
        }
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// An embedded ERD-Ultra project: ER diagram, relational schema or SQL, drawn by ERD-Ultra's own renderer (#204).
struct ErdBlockView: View {
    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument
    @Environment(\.colorScheme) private var colorScheme
    @State private var result: RenderScript.Result?
    @State private var previewHeight: CGFloat = 120
    @State private var message: String?
    @State private var fileMissing = false
    /// A copy opened in ERD-Ultra for a block without original file; followed while Folio runs.
    @State private var editingCopy: URL?

    private var view: ErduDocument.View { ErduDocument.View(rawValue: block.mode) ?? .er }
    private var watchedFile: URL? { block.linkedFile.map { URL(fileURLWithPath: $0) } ?? editingCopy }

    var body: some View {
        EmbedCard(title: title, icon: "point.3.filled.connected.trianglepath.dotted",
                  height: .constant(0), resizable: false, onCommit: {}) {
            actions
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                viewPicker
                preview
                statusLines
            }
        }
        .task(id: watchedFile) { await follow() }
    }

    private var title: String {
        let name = block.caption.isEmpty ? "ER-Diagramm" : block.caption
        return name + " · ERD-Ultra"
    }

    private var viewPicker: some View {
        Picker("Ansicht", selection: Binding(get: { view }, set: { v in
            doc.changeBlock(block, "Ansicht ändern") { block.mode = v.rawValue }
        })) {
            ForEach(ErduDocument.View.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 420)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var preview: some View {
        RenderPreview(kind: .erd, source: block.storage.string,
                      options: RenderScript.Options(dark: colorScheme == .dark, fontSize: 13, view: view.rawValue)) { r in
            result = r
            if r.ok { previewHeight = max(CGFloat(r.pageHeight), 40) }
        }
        .frame(height: previewHeight)
        .frame(maxWidth: .infinity)
        .opacity(result?.ok == false ? 0.35 : 1)
        .padding(.vertical, 4)
        .accessibilityLabel("\(view.title) aus \(block.caption)")
    }

    @ViewBuilder private var statusLines: some View {
        if let error = result.flatMap({ $0.ok ? nil : $0.error }) {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                .padding(.horizontal, 12).padding(.bottom, 6)
        }
        if fileMissing, let path = block.linkedFile {
            Label("Originaldatei nicht gefunden: \(path)", systemImage: "questionmark.folder").font(.caption).foregroundStyle(.orange)
                .padding(.horizontal, 12).padding(.bottom, 6)
        }
        if let message {
            Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    @ViewBuilder private var actions: some View {
        Button { openInErdUltra() } label: { Label("In ERD-Ultra öffnen", systemImage: "arrow.up.forward.app") }
            .disabled(ErdBlocks.appURL == nil)
            .help(ErdBlocks.appURL == nil ? "ERD-Ultra ist nicht installiert (github.com/gigafrosxh/erd-ultra/releases)" : "In ERD-Ultra bearbeiten; gespeicherte Änderungen erscheinen hier")
        Menu {
            Button("Bild kopieren") { Task { await copyImage() } }
            Button("SQL kopieren") { Task { await copySQL() } }
            Divider()
            Button("Als SVG sichern …") { Task { await export(.svg) } }.disabled(view == .sql)
            Button("Als PNG sichern …") { Task { await export(.png) } }
            Button("Als PDF sichern …") { Task { await export(.pdf) } }
            Divider()
            Button(block.linkedFile == nil ? "Mit .erdu-Datei verknüpfen …" : "Andere .erdu-Datei verknüpfen …") { relink() }
            if let path = block.linkedFile {
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                Button("Verknüpfung lösen") { doc.changeBlock(block, "Verknüpfung lösen") { block.linkedFile = nil }; fileMissing = false }
            }
        } label: {
            Label("Mehr", systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Exportieren und Verknüpfung")
    }

    // MARK: Following the file

    /// Checks the file about once a second (ERD-Ultra rewrites it in place); never steals focus.
    private func follow() async {
        guard let url = watchedFile else { fileMissing = false; return }
        var last = ErdBlocks.modificationDate(url)
        if let last, block.linkedFile != nil, last > (doc.meta.modified) { message = ErdBlocks.pull(url, into: block, doc: doc) }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(800))
            let now = ErdBlocks.modificationDate(url)
            fileMissing = now == nil && block.linkedFile != nil
            guard let now, now != last else { continue }
            last = now
            if let note = ErdBlocks.pull(url, into: block, doc: doc) { message = note }
        }
    }

    private func relink() {
        guard let url = ErdBlocks.pickFile() else { return }
        doc.changeBlock(block, "Mit Datei verknüpfen") { block.linkedFile = url.path }
        message = ErdBlocks.pull(url, into: block, doc: doc) ?? "Verknüpft mit \(url.lastPathComponent)."
    }

    private func openInErdUltra() {
        guard let app = ErdBlocks.appURL else { return }
        var url = watchedFile
        if url == nil || !FileManager.default.fileExists(atPath: url!.path) {
            // No original: hand ERD-Ultra a copy and follow it.
            let folder = AttachmentSync.cacheRoot.appendingPathComponent(doc.id.uuidString).appendingPathComponent(block.id.uuidString)
            let copy = folder.appendingPathComponent((block.caption.isEmpty ? "Diagramm" : block.caption) + ".erdu")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(block.storage.string.utf8).write(to: copy, options: .atomic)
            } catch {
                message = "Kopie konnte nicht angelegt werden: \(error.localizedDescription)"
                return
            }
            if block.linkedFile == nil { editingCopy = copy }
            url = copy
        }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url!], withApplicationAt: app, configuration: config)
    }

    // MARK: Export

    private func render(_ v: ErduDocument.View) async -> OffscreenRenderer.Output? {
        do {
            message = nil
            return try await OffscreenRenderer.render(.erd, source: block.storage.string, width: 1100,
                                                      options: RenderScript.Options(dark: false, fontSize: 13, view: v.rawValue))
        } catch {
            message = "Export nicht möglich: \(error.localizedDescription)"
            return nil
        }
    }

    private func copyImage() async {
        guard let out = await render(view) else { return }
        NSPasteboard.general.clearContents()
        let item = NSPasteboardItem()
        item.setData(out.pdf, forType: .pdf)
        if let png = OffscreenRenderer.png(from: out) { item.setData(png, forType: .png) }
        NSPasteboard.general.writeObjects([item])
        message = "Bild in die Zwischenablage kopiert."
    }

    private func copySQL() async {
        if view == .sql, let sql = result?.sql { return putString(sql) }
        guard let sql = try? await OffscreenRenderer.renderResult(.erd, source: block.storage.string,
                                                                   options: RenderScript.Options(view: "sql")).sql else {
            message = "SQL konnte nicht erzeugt werden."
            return
        }
        putString(sql)
    }

    private func putString(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        message = "SQL in die Zwischenablage kopiert."
    }

    private func export(_ type: UTType) async {
        guard let out = await render(view) else { return }
        let data: Data? = switch type {
        case .svg: out.svg.map { Data($0.utf8) }
        case .png: OffscreenRenderer.png(from: out)
        default: out.pdf
        }
        guard let data else { message = "Export nicht möglich."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = (block.caption.isEmpty ? "ER-Diagramm" : block.caption) + "." + (type.preferredFilenameExtension ?? "dat")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            message = "Gesichert: \(url.lastPathComponent)"
        } catch {
            message = "Sichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}

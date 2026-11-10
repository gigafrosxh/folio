import AppKit
import UniformTypeIdentifiers
import FolioCore

/// Markdown import and export (#4).
///
/// Export writes `<Titel>.md` and, when the note has attachments, a folder `<Titel> Dateien/` next to
/// it that the Markdown links to. Import reads headings, lists, checklists, bold/italic/strikethrough,
/// inline code, links, fenced code (Mermaid becomes a diagram, ```math/$$ a formula) and local images.
@MainActor
enum MarkdownTransfer {
    // MARK: Export

    static func exportWithPanel(_ doc: NoteDocument) {
        doc.saveNow()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = MarkdownStructure.safeFileName(doc.meta.title.isEmpty ? "Notiz" : doc.meta.title) + ".md"
        panel.message = "Anhänge werden in einen Ordner neben der Markdown-Datei kopiert."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try export(doc.makeFilePreview(), to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NoteStore.shared.lastError = "Markdown-Export fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    /// Exports every note of a folder (with subfolders) into `target`, keeping the folder structure.
    static func exportFolderWithPanel(_ folder: URL) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Exportieren"
        panel.message = "Zielordner für den Markdown-Export von „\(folder.lastPathComponent)“"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        NoteStore.shared.saveAll()
        let root = target.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        var failures: [String] = []
        let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == FolioArchive.fileExtension else { continue }
            let rel = String(url.deletingLastPathComponent().standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count))
            let dir = root.appendingPathComponent(rel, isDirectory: true)
            do {
                let file = try NoteFile.read(from: url)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let name = MarkdownStructure.safeFileName(file.meta.title.isEmpty ? url.deletingPathExtension().lastPathComponent : file.meta.title)
                try export(file, to: uniqueURL(dir.appendingPathComponent(name + ".md")))
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { NoteStore.shared.lastError = "Nicht exportiert:\n" + failures.joined(separator: "\n") }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    static func export(_ file: NoteFile, to url: URL) throws {
        let base = url.deletingPathExtension().lastPathComponent
        let filesDir = url.deletingLastPathComponent().appendingPathComponent(base + " Dateien", isDirectory: true)
        let (markdown, attachments) = markdown(for: file, filesFolder: filesDir.lastPathComponent)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        if !attachments.isEmpty {
            try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
            for (name, att) in attachments {
                let dest = filesDir.appendingPathComponent(name)
                if att.header.isPackage, let wrapper = FileWrapper(serializedRepresentation: att.data) {
                    try? FileManager.default.removeItem(at: dest)
                    try wrapper.write(to: dest, options: .atomic, originalContentsURL: nil)
                } else {
                    try att.data.write(to: dest, options: .atomic)
                }
            }
        }
    }

    // MARK: Import

    static func importWithPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText, .plainText]
        panel.message = "Markdown-Dateien oder einen Ordner mit Markdown-Dateien wählen"
        panel.prompt = "Importieren"
        guard panel.runModal() == .OK else { return }
        var files: [URL] = []
        for url in panel.urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL {
                    if ["md", "markdown"].contains(f.pathExtension.lowercased()) { files.append(f) }
                }
            } else {
                files.append(url)
            }
        }
        importFiles(files)
    }

    /// Imports the files into the selected folder; returns how many worked.
    @discardableResult
    static func importFiles(_ urls: [URL], into folder: URL? = nil) -> Int {
        let store = NoteStore.shared
        let dir = folder ?? store.targetFolder
        var failures: [String] = []
        var last: UUID?
        for url in urls {
            do {
                let file = try note(fromMarkdownAt: url)
                let target = uniqueURL(dir.appendingPathComponent(NoteStore.sanitize(file.meta.title)).appendingPathExtension(FolioArchive.fileExtension))
                try file.write(to: target)
                last = file.meta.id
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        store.reload()
        if let last { store.open(noteID: last) }
        if !failures.isEmpty { store.lastError = "Nicht importiert:\n" + failures.joined(separator: "\n") }
        return urls.count - failures.count
    }

    static func note(fromMarkdownAt url: URL) throws -> NoteFile {
        let data = try Data(contentsOf: url)
        guard let markdown = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return note(fromMarkdown: markdown, title: url.deletingPathExtension().lastPathComponent, baseURL: url.deletingLastPathComponent())
    }

    static func note(fromMarkdown markdown: String, title: String, baseURL: URL?) -> NoteFile {
        var blocks: [BlockRecord] = []
        var attachments: [FolioArchive.Attachment] = []
        for piece in MarkdownStructure.pieces(markdown) {
            switch piece {
            case .text(let text):
                var b = BlockRecord(kind: .text)
                b.rtf = RichTextCodec.rtfData(from: attributed(fromMarkdown: text))
                blocks.append(b)
            case .code(let lang, let code):
                var b = BlockRecord(kind: .code)
                b.code = code
                b.language = Languages.all.first { $0.id == lang || $0.name.lowercased() == lang }?.id ?? (lang.isEmpty ? "plain" : lang)
                blocks.append(b)
            case .mermaid(let source):
                var b = BlockRecord(kind: .diagram)
                b.code = source
                blocks.append(b)
            case .math(let source):
                var b = BlockRecord(kind: .math)
                b.code = source
                blocks.append(b)
            case .image(let alt, let path):
                let decoded = path.removingPercentEncoding ?? path
                if let base = baseURL, !decoded.contains("://"),
                   let data = try? Data(contentsOf: base.appendingPathComponent(decoded)) {
                    let name = (decoded as NSString).lastPathComponent
                    let a = FolioArchive.Attachment(filename: name, typeIdentifier: UTType(filenameExtension: (name as NSString).pathExtension)?.identifier ?? "public.image", data: data)
                    attachments.append(a)
                    var b = BlockRecord(kind: .image)
                    b.attachmentID = a.id
                    b.width = 1
                    if !alt.isEmpty { b.caption = alt }
                    blocks.append(b)
                } else if decoded.hasPrefix("http") {
                    var b = BlockRecord(kind: .web)
                    b.url = decoded
                    b.mode = "preview"
                    blocks.append(b)
                } else {
                    var b = BlockRecord(kind: .text)
                    b.rtf = RichTextCodec.rtfData(from: NSAttributedString(string: "[Bild fehlt: \(path)]", attributes: ThemeManager.shared.bodyAttributes))
                    blocks.append(b)
                }
            }
        }
        var meta = NoteMetadata(title: MarkdownStructure.title(of: markdown, fallback: title))
        meta.created = Date()
        // Titles, tags, kinds and links are refreshed exactly like for notes written in Folio.
        let doc = NoteDocument(file: NoteFile(meta: meta, body: NoteBody(blocks: blocks), attachments: attachments), url: URL(fileURLWithPath: "/dev/null"))
        return doc.makeFile()
    }

    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension, dir = url.deletingLastPathComponent()
        var n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent("\(base) \(n).\(ext)").path) { n += 1 }
        return dir.appendingPathComponent("\(base) \(n).\(ext)")
    }
}

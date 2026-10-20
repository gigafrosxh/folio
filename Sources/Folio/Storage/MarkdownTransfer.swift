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
        NoteStore.shared.currentDocument?.saveNow()
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

    /// The Markdown text and the attachments to write (file name → attachment).
    static func markdown(for file: NoteFile, filesFolder: String) -> (String, [(String, FolioArchive.Attachment)]) {
        var parts: [String] = []
        var files: [(String, FolioArchive.Attachment)] = []
        var usedNames = Set<String>()
        func attachmentLink(_ id: UUID?) -> (name: String, path: String)? {
            guard let id, let att = file.attachments.first(where: { $0.id == id }) else { return nil }
            var name = MarkdownStructure.safeFileName(att.header.filename)
            if usedNames.contains(name) { name = "\(id.uuidString.prefix(6))-\(name)" }
            usedNames.insert(name)
            files.append((name, att))
            let path = (filesFolder + "/" + name).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            return (name, path)
        }
        for b in file.body.blocks {
            switch b.kind {
            case .text:
                let s = RichTextCodec.attributedString(from: b.rtf)
                let md = markdown(from: s)
                if !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(md) }
            case .code:
                parts.append("```\(b.language ?? "")\n\(b.code ?? "")\n```")
                if let out = b.output, !out.isEmpty { parts.append("```text\n\(out)\n```") }
            case .database:
                parts.append("```sql\n\(b.code ?? "")\n```")
            case .math:
                parts.append("$$\n\(b.code ?? "")\n$$")
            case .diagram:
                parts.append("```mermaid\n\(b.code ?? "")\n```")
            case .image, .drawing:
                if b.kind == .drawing {
                    // Drawings are exported as their PencilKit data; a PNG preview is not available here.
                    if let link = attachmentLink(b.attachmentID) { parts.append("[Zeichnung](\(link.path))") }
                } else if let link = attachmentLink(b.attachmentID) {
                    parts.append("![\(b.caption ?? "")](\(link.path))")
                }
            case .pdf, .file, .audio:
                if let link = attachmentLink(b.attachmentID) { parts.append("[\(link.name)](\(link.path))") }
                if b.kind == .audio, let t = b.output, !t.isEmpty { parts.append("> " + t.replacingOccurrences(of: "\n", with: "\n> ")) }
            case .web:
                if let u = b.url { parts.append("[\(b.caption?.isEmpty == false ? b.caption! : u)](\(u))") }
            }
        }
        return (parts.joined(separator: "\n\n") + "\n", files)
    }

    /// Rich text to Markdown: headings from the font size, bold/italic/strikethrough/code spans,
    /// links (note links stay folio:// links), Folio's list markers to Markdown lists.
    static func markdown(from s: NSAttributedString) -> String {
        let base = CGFloat(ThemeManager.shared.settings.editorFontSize)
        let ns = s.string as NSString
        var lines: [String] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs]) { _, range, _, _ in
            var line = ""
            s.enumerateAttributes(in: range) { attrs, r, _ in
                var text = ns.substring(with: r)
                guard !text.isEmpty else { return }
                let font = attrs[.font] as? NSFont
                let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                let isHeading = (font?.pointSize ?? base) > base * 1.05
                let mono = font?.isFixedPitch == true
                let lead = String(text.prefix { $0 == " " }), trail = String(text.reversed().prefix { $0 == " " })
                var core = text.trimmingCharacters(in: .whitespaces)
                if !core.isEmpty {
                    if mono { core = "`\(core)`" } else {
                        core = core.replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_")
                        if traits.contains(.boldFontMask) && !isHeading { core = "**\(core)**" }
                        if traits.contains(.italicFontMask) { core = "*\(core)*" }
                        if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { core = "~~\(core)~~" }
                    }
                    if let link = attrs[.link] {
                        let url = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                        core = "[\(core)](\(url))"
                    }
                    text = lead + core + trail
                }
                line += text
            }
            // Headings by size (title / heading / subheading).
            if let font = range.length > 0 ? s.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont : nil,
               !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let size = font.pointSize
                if size >= base * 1.7 { line = "# " + line }
                else if size >= base * 1.3 { line = "## " + line }
                else if size > base * 1.05 { line = "### " + line }
            }
            // Folio's list markers: tabs for indentation, then •, ☐, ☑ or "1.".
            let tabs = line.prefix { $0 == "\t" }.count
            var rest = String(line.dropFirst(tabs))
            let indent = String(repeating: "  ", count: tabs)
            if rest.hasPrefix("• ") { rest = "- " + rest.dropFirst(2) }
            else if rest.hasPrefix("☐ ") { rest = "- [ ] " + rest.dropFirst(2) }
            else if rest.hasPrefix("☑ ") { rest = "- [x] " + rest.dropFirst(2) }
            else if tabs == 0, rest.hasPrefix("—") && rest.trimmingCharacters(in: CharacterSet(charactersIn: "— ")).isEmpty { rest = "---" }
            lines.append(indent + rest)
        }
        return lines.joined(separator: "\n")
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

    /// Inline Markdown in a run of text lines to Folio rich text.
    static func attributed(fromMarkdown text: String) -> NSAttributedString {
        let theme = ThemeManager.shared
        let body = theme.bodyAttributes
        let out = NSMutableAttributedString()
        let codeFont = NSFont.monospacedSystemFont(ofSize: theme.bodyFont().pointSize * 0.92, weight: .regular)
        let inline = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*|__(.+?)__|~~(.+?)~~|(?<![\*\w])\*(?!\s)(.+?)\*(?!\*)|(?<![_\w])_(?!\s)(.+?)_(?!\w)|`([^`]+)`|\[([^\]]+)\]\(([^)\s]+)\)"#)
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            var line = raw
            var attrs = body
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            let level = leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
            let tabs = String(repeating: "\t", count: level)
            if let r = line.range(of: #"^#{1,6} "#, options: .regularExpression) {
                let hashes = line[r].filter { $0 == "#" }.count
                line.removeSubrange(r)
                attrs = (hashes == 1 ? TextStyle.title : hashes == 2 ? TextStyle.heading : TextStyle.subheading).attributes(theme: theme)
            } else if let r = line.range(of: #"^\s*[-*+] \[ \] "#, options: .regularExpression) {
                line.replaceSubrange(r, with: tabs + "☐ ")
            } else if let r = line.range(of: #"^\s*[-*+] \[[xX]\] "#, options: .regularExpression) {
                line.replaceSubrange(r, with: tabs + "☑ ")
            } else if let r = line.range(of: #"^\s*[-*+] "#, options: .regularExpression) {
                line.replaceSubrange(r, with: tabs + "• ")
            } else if line.range(of: #"^\s*\d+[.)] "#, options: .regularExpression) != nil {
                line = tabs + line.replacingOccurrences(of: #"^\s*(\d+)[.)] "#, with: "$1. ", options: .regularExpression)
            } else if let r = line.range(of: #"^\s*> ?"#, options: .regularExpression) {
                line.removeSubrange(r)
                attrs = TextStyle.quote.attributes(theme: theme)
            } else if line.trimmingCharacters(in: .whitespaces).range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                line = "———"
            }
            if i > 0 { out.append(NSAttributedString(string: "\n", attributes: attrs)) }
            let ns = line as NSString
            var cursor = 0
            for m in inline.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                if m.range.location > cursor {
                    out.append(NSAttributedString(string: unescape(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))), attributes: attrs))
                }
                var a = attrs
                let font = a[.font] as? NSFont ?? theme.bodyFont()
                func group(_ n: Int) -> String? { m.range(at: n).location != NSNotFound ? ns.substring(with: m.range(at: n)) : nil }
                var content = ""
                if let t = group(1) ?? group(2) { content = t; a[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                else if let t = group(3) { content = t; a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                else if let t = group(4) ?? group(5) { content = t; a[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                else if let t = group(6) { content = t; a[.font] = codeFont; a[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.12) }
                else if let t = group(7), let u = group(8) { content = t; a[.link] = URL(string: u) ?? u }
                out.append(NSAttributedString(string: unescape(content), attributes: a))
                cursor = NSMaxRange(m.range)
            }
            if cursor < ns.length { out.append(NSAttributedString(string: unescape(ns.substring(from: cursor)), attributes: attrs)) }
        }
        return out
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+\-.!~])"#, with: "$1", options: .regularExpression)
    }

    private static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension, dir = url.deletingLastPathComponent()
        var n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent("\(base) \(n).\(ext)").path) { n += 1 }
        return dir.appendingPathComponent("\(base) \(n).\(ext)")
    }
}

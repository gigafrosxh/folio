import AppKit
import PDFKit
import PencilKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import FolioCore

/// Exports a whole note as a paginated PDF (A4): rich text, images, drawings, embedded PDFs, code with
/// syntax colors, optionally the code output, formulas and diagrams (as vector graphics) and transcripts.
@MainActor
enum NotePDFExporter {
    struct Options {
        var includeOutputs = true
        var paper = NSSize(width: 595.28, height: 841.89)   // A4 in points
        var margin: CGFloat = 50
    }

    enum ExportError: LocalizedError {
        case write(String)
        var errorDescription: String? {
            if case .write(let m) = self { return "Das PDF konnte nicht gesichert werden: \(m)" }
            return nil
        }
    }

    // MARK: UI

    static func exportWithPanel(_ doc: NoteDocument) {
        doc.saveNow()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let title = doc.meta.title.isEmpty ? "Notiz" : doc.meta.title
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".pdf"
        let check = NSButton(checkboxWithTitle: "Ausgaben von Code-Blöcken einschließen", target: nil, action: nil)
        check.state = UserDefaults.standard.object(forKey: "folio.pdfIncludeOutputs") as? Bool == false ? .off : .on
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 36))
        check.frame.origin = NSPoint(x: 16, y: 9)
        check.sizeToFit()
        box.addSubview(check)
        panel.accessoryView = box
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let include = check.state == .on
        UserDefaults.standard.set(include, forKey: "folio.pdfIncludeOutputs")
        Task {
            do {
                try await export(doc, to: url, options: Options(includeOutputs: include))
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                let alert = NSAlert()
                alert.messageText = "PDF-Export fehlgeschlagen"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    // MARK: Export

    /// Writes the PDF; the note itself is only read.
    static func export(_ doc: NoteDocument, to url: URL, options: Options = Options()) async throws {
        let width = options.paper.width - 2 * options.margin
        let maxImageHeight = options.paper.height - 2 * options.margin - 40
        // Colors are resolved when the print view (light appearance) draws, so the note prints like paper.
        let content = await buildContent(doc, width: width, maxImageHeight: maxImageHeight, options: options)
        try write(content, title: doc.meta.title, to: url, options: options)
    }

    /// The note as PDF data, for printing (#169). The print system can only write PDFs to a file, so it goes
    /// through a private temporary folder that is removed again before this returns, also on errors.
    static func pdfData(_ doc: NoteDocument, options: Options = Options()) async throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-print-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Notiz.pdf")
        try await export(doc, to: url, options: options)
        return try Data(contentsOf: url)
    }

    static func write(_ content: NSAttributedString, title: String, to url: URL, options: Options) throws {
        let info = NSPrintInfo()
        info.paperSize = options.paper
        info.topMargin = options.margin
        info.bottomMargin = options.margin
        info.leftMargin = options.margin
        info.rightMargin = options.margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = true

        let width = options.paper.width - 2 * options.margin
        let view = PrintTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.noteTitle = title
        view.appearance = NSAppearance(named: .aqua)
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(content)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let used = view.layoutManager?.usedRect(for: view.textContainer!).height ?? 100
        view.setFrameSize(NSSize(width: width, height: ceil(used)))

        try? FileManager.default.removeItem(at: url)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: url.path) else {
            throw ExportError.write("Der Druckauftrag ist fehlgeschlagen.")
        }
    }

    // MARK: Building the document

    static func buildContent(_ doc: NoteDocument, width: CGFloat, maxImageHeight: CGFloat, options: Options) async -> NSAttributedString {
        await ContentBuilder(doc: doc, width: width, maxImageHeight: maxImageHeight, options: options).build()
    }

    private static func bodyAttributes(_ theme: ThemeManager) -> [NSAttributedString.Key: Any] {
        var a = theme.bodyAttributes
        a[.foregroundColor] = NSColor.black
        return a
    }

    /// Text as written, but readable on paper: dark-mode-only colors (labelColor & co.) resolve against
    /// the light appearance, and missing colors become black.
    private static func printable(_ text: NSAttributedString) -> NSAttributedString {
        let s = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: s.length)
        s.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if value == nil { s.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        if !s.string.hasSuffix("\n") { s.append(NSAttributedString(string: "\n", attributes: s.attributes(at: max(s.length - 1, 0), effectiveRange: nil))) }
        return s
    }

    private static func paragraph(spacingBefore: CGFloat, spacingAfter: CGFloat) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = spacingBefore
        p.paragraphSpacing = spacingAfter
        return p
    }

    private static func attachment(_ image: NSImage, maxWidth: CGFloat, maxHeight: CGFloat, centered: Bool) -> NSAttributedString {
        var size = image.size
        if size.width > maxWidth { size = NSSize(width: maxWidth, height: size.height * maxWidth / size.width) }
        if size.height > maxHeight { size = NSSize(width: size.width * maxHeight / size.height, height: maxHeight) }
        let a = NSTextAttachment()
        a.image = image
        a.bounds = CGRect(origin: .zero, size: size)
        let s = NSMutableAttributedString(attachment: a)
        let p = NSMutableParagraphStyle()
        p.alignment = centered ? .center : .left
        p.paragraphSpacingBefore = 4
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        return s
    }

    /// Each page of an embedded PDF as its own vector image.
    private static func pdfPages(_ data: Data) -> [NSImage] {
        guard let first = NSPDFImageRep(data: data) else { return [] }
        return (0..<first.pageCount).compactMap { i in
            guard let rep = NSPDFImageRep(data: data) else { return nil }
            rep.currentPage = i
            let image = NSImage(size: rep.bounds.size)
            image.addRepresentation(rep)
            return image
        }
    }

    /// Quick Look preview of a document (e.g. the first sheet of a Numbers table).
    private static func thumbnail(_ att: FolioArchive.Attachment, noteID: UUID, width: CGFloat) async -> NSImage? {
        guard let url = AttachmentSync.materialize(att, noteID: noteID) else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: width, height: width * 1.3),
                                                   scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

/// The printed note: title in the header, page number in the footer.
final class PrintTextView: NSTextView {
    var noteTitle = ""

    override var pageHeader: NSAttributedString {
        NSAttributedString(string: noteTitle, attributes: [.font: NSFont.systemFont(ofSize: 8.5), .foregroundColor: NSColor.gray])
    }

    override var pageFooter: NSAttributedString {
        let page = NSPrintOperation.current?.currentPage ?? 1
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        return NSAttributedString(string: "\(page)", attributes: [.font: NSFont.systemFont(ofSize: 8.5), .foregroundColor: NSColor.gray, .paragraphStyle: p])
    }
}

// MARK: Content

extension NotePDFExporter {
    /// Turns the note's blocks, one kind at a time, into the attributed text that gets printed (#144).
    @MainActor
    private final class ContentBuilder {
        private let out = NSMutableAttributedString()
        private let doc: NoteDocument
        private let width: CGFloat
        private let maxImageHeight: CGFloat
        private let options: Options
        private let body: [NSAttributedString.Key: Any]
        private let codeTheme: CodeTheme
        private let gap = paragraph(spacingBefore: 4, spacingAfter: 10)
        private let lightBox = NSColor(white: 0.96, alpha: 1)
        private let codeFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)

        init(doc: NoteDocument, width: CGFloat, maxImageHeight: CGFloat, options: Options) {
            self.doc = doc
            self.width = width
            self.maxImageHeight = maxImageHeight
            self.options = options
            let theme = ThemeManager.shared
            body = bodyAttributes(theme)
            codeTheme = theme.codeTheme(dark: false)
        }

        func build() async -> NSAttributedString {
            for block in doc.blocks { await append(block) }
            // Trailing line breaks would start an empty last page.
            while out.length > 0, let last = out.string.last, last.isNewline || last == " " {
                out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
            }
            return out
        }

        private func append(_ block: BlockModel) async {
            switch block.kind {
            case .text: appendText(block)
            case .embed: appendEmbed(block)
            case .code: appendCode(block)
            case .database: appendDatabase(block)
            case .image: appendPicture(block)
            case .drawing: appendDrawing(block)
            case .pdf: appendPDF(block)
            case .file: await appendFile(block)
            case .web: appendWeb(block)
            case .math, .diagram: await appendRendered(block)
            case .audio: appendAudio(block)
            }
        }

        private func attachment(of block: BlockModel) -> FolioArchive.Attachment? {
            block.attachmentID.flatMap { doc.attachments[$0] }
        }

        // MARK: Blocks

        private func appendText(_ block: BlockModel) {
            guard block.storage.length > 0 else { return }
            newline()
            out.append(printable(block.storage))
        }

        /// The embedded note's text, as it reads in the editor (#120).
        private func appendEmbed(_ block: BlockModel) {
            let title = block.storage.string
            appendLabel("Eingebettet: \(title)", icon: "↳")
            let store = NoteStore.shared
            guard let id = store.linkIndex.resolve(title), id != doc.id,
                  let ref = store.notes.first(where: { $0.id == id }), let file = try? NoteFile.read(from: ref.url) else { return }
            for text in file.body.blocks.filter({ $0.kind == .text }).map({ RichTextCodec.attributedString(from: $0.rtf) }) where text.length > 0 {
                newline()
                out.append(printable(text))
            }
        }

        private func appendCode(_ block: BlockModel) {
            let spec = Languages.spec(for: block.language)
            appendLabel(spec.name, icon: "⌘")
            let code = block.storage.string
            let background = codeTheme.backgroundColor.blended(withFraction: 0.5, of: lightBox) ?? .white
            appendBox(code, font: codeFont, background: background, foreground: codeTheme.foregroundColor,
                      tokens: SyntaxHighlighter.tokens(in: code, language: spec), colors: codeTheme)
            appendOutput(of: block)
        }

        private func appendOutput(of block: BlockModel) {
            guard options.includeOutputs, let output = block.output?.trimmingCharacters(in: .newlines), !output.isEmpty else { return }
            appendLabel(block.outputIsError ? "Fehler" : "Ausgabe", icon: "▸")
            appendBox(String(output.prefix(20_000)), font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                      background: NSColor(white: 0.95, alpha: 1),
                      foreground: block.outputIsError ? .systemRed : NSColor(white: 0.25, alpha: 1))
        }

        private func appendDatabase(_ block: BlockModel) {
            appendLabel("SQL" + (block.connection.map { " · \($0.name)" } ?? ""), icon: "⛁")
            let code = block.storage.string
            appendBox(code, font: codeFont, background: lightBox, foreground: codeTheme.foregroundColor,
                      tokens: SyntaxHighlighter.tokens(in: code, language: Languages.spec(for: "sql")), colors: codeTheme)
        }

        private func appendPicture(_ block: BlockModel) {
            // Printed and exported as shown: with crop and rotation (#45).
            guard let data = attachment(of: block)?.data,
                  let image = EditedImage.image(data, edit: block.imageEdit, key: block.id.uuidString) else { return }
            appendImage(image, fraction: CGFloat(block.width))
            appendCaption(block.caption)
        }

        private func appendDrawing(_ block: BlockModel) {
            guard let data = attachment(of: block)?.data, let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty else { return }
            var image: NSImage?
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                image = drawing.image(from: drawing.bounds.insetBy(dx: -10, dy: -10), scale: 2)
            }
            if let image { appendImage(image) }
        }

        private func appendPDF(_ block: BlockModel) {
            guard let att = attachment(of: block) else { return }
            appendLabel(att.header.filename, icon: "📄")
            for page in pdfPages(att.data) { appendImage(page) }
        }

        private func appendFile(_ block: BlockModel) async {
            guard let att = attachment(of: block) else { return }
            appendLabel(att.header.filename, icon: "📎")
            if let thumb = await thumbnail(att, noteID: doc.id, width: width) { appendImage(thumb) }
        }

        private func appendWeb(_ block: BlockModel) {
            guard !block.url.isEmpty else { return }
            newline()
            var attrs = body
            attrs[.link] = URL(string: block.url)
            attrs[.foregroundColor] = NSColor.linkColor
            out.append(NSAttributedString(string: "🔗 " + block.url + "\n", attributes: attrs))
            appendCaption(block.caption)
        }

        private func appendRendered(_ block: BlockModel) async {
            let kind: RenderScript.Kind = block.kind == .math ? .math : .diagram
            let source = block.storage.string
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let options = RenderScript.Options(dark: false, fontSize: kind == .math ? 16 : 13)
            if let rendered = try? await OffscreenRenderer.render(kind, source: source, width: width, options: options),
               let image = OffscreenRenderer.image(from: rendered) {
                appendImage(image)
            } else {
                appendBox(source, font: codeFont, background: lightBox, foreground: .black)
            }
        }

        private func appendAudio(_ block: BlockModel) {
            let att = attachment(of: block)
            var label = att?.header.filename ?? "Audioaufnahme"
            if let att, let url = AttachmentSync.materialize(att, noteID: doc.id), let d = try? AudioAnalysis.duration(of: url) {
                label += " · " + AudioAnalysis.format(d)
            }
            appendLabel(label, icon: "🔊")
            if let transcript = block.output, !transcript.isEmpty {
                out.append(NSAttributedString(string: transcript + "\n", attributes: body))
            }
        }

        // MARK: Pieces

        private func newline() {
            if out.length > 0, !out.string.hasSuffix("\n") { out.append(NSAttributedString(string: "\n", attributes: body)) }
        }

        private func appendImage(_ image: NSImage, fraction: CGFloat = 1) {
            newline()
            out.append(NotePDFExporter.attachment(image, maxWidth: width * fraction, maxHeight: maxImageHeight, centered: true))
            out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: gap]))
        }

        private func appendCaption(_ text: String) {
            guard !text.isEmpty else { return }
            let style = paragraph(spacingBefore: 0, spacingAfter: 10)
            style.alignment = .center
            out.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]))
        }

        private func appendLabel(_ text: String, icon: String) {
            newline()
            out.append(NSAttributedString(string: "\(icon)  \(text)\n", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph(spacingBefore: 8, spacingAfter: 3)]))
        }

        private func appendBox(_ text: String, font: NSFont, background: NSColor, foreground: NSColor, tokens: [Token] = [], colors: CodeTheme? = nil) {
            newline()
            let text = text.isEmpty ? " " : text
            let s = NSMutableAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: foreground, .paragraphStyle: boxStyle(background)])
            if let colors {
                for token in tokens where NSMaxRange(token.range) <= (text as NSString).length {
                    s.addAttribute(.foregroundColor, value: colors.color(for: token.kind), range: token.range)
                }
            }
            out.append(s)
            out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
        }

        private func boxStyle(_ background: NSColor) -> NSParagraphStyle {
            let block = NSTextBlock()
            block.backgroundColor = background
            block.setWidth(8, type: .absoluteValueType, for: .padding)
            block.setWidth(0.5, type: .absoluteValueType, for: .border)
            block.setBorderColor(NSColor.black.withAlphaComponent(0.08))
            block.setValue(100, type: .percentageValueType, for: .width)
            let style = NSMutableParagraphStyle()
            style.textBlocks = [block]
            style.lineBreakMode = .byCharWrapping
            return style
        }
    }
}

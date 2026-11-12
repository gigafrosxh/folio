import AppKit
import PDFKit
import UniformTypeIdentifiers
import FolioCore

/// PDFs as notes (#130): title and text become editable note text, the original PDF stays attached
/// below it, so nothing of the document is lost.
@MainActor
enum PDFImport {
    static func importWithPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf]
        panel.message = "PDF-Dateien wählen – jede wird eine eigene Notiz"
        panel.prompt = "Importieren"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// Imports into the selected folder; returns the new notes.
    @discardableResult
    static func importFiles(_ urls: [URL], into folder: URL? = nil) -> [NoteRef] {
        let store = NoteStore.shared
        let dir = folder ?? store.targetFolder
        var created: [NoteRef] = []
        var failures: [String] = []
        for url in urls {
            do {
                let file = try note(fromPDFAt: url)
                let target = MarkdownTransfer.uniqueURL(dir.appendingPathComponent(NoteStore.sanitize(file.meta.title)).appendingPathExtension(FolioArchive.fileExtension))
                try file.write(to: target)
                created.append(NoteRef(meta: file.meta, url: target))
            } catch PDFText.Failure.locked {
                failures.append("\(url.lastPathComponent): Die PDF ist mit einem Passwort geschützt.")
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        store.reload()
        if let last = created.last { store.open(noteID: last.id) }
        if !failures.isEmpty { store.lastError = "Nicht importiert:\n" + failures.joined(separator: "\n") }
        return created
    }

    /// Headings, paragraphs, lists and pictures as in the PDF (#167); the original PDF stays attached at the end.
    static func note(fromPDFAt url: URL) throws -> NoteFile {
        let data = try Data(contentsOf: url)
        guard let document = PDFDocument(data: data) else { throw PDFText.Failure.notAPDF }
        guard !document.isLocked else { throw PDFText.Failure.locked }
        let elements = PDFStructure.elements(of: PDFStructure.pages(of: document))
        var note = PDFNoteBuilder(theme: ThemeManager.shared)
        if !startsWithTitle(elements) { note.addTitle(documentTitle(document) ?? url.deletingPathExtension().lastPathComponent) }
        if !elements.contains(where: isText) {
            note.addParagraph([PDFStructure.Run(text: "Diese PDF enthält keinen auswählbaren Text (z. B. ein Scan). Sie ist unten angehängt.")])
        }
        elements.forEach { note.add($0) }
        let attachment = FolioArchive.Attachment(filename: url.lastPathComponent, typeIdentifier: UTType.pdf.identifier, data: data)
        note.addAttachmentBlock(.pdf, attachment)
        let file = NoteFile(meta: NoteMetadata(title: ""), body: NoteBody(blocks: note.blocks), attachments: note.attachments)
        // Title, preview, search text and kinds are derived exactly like for notes written in Folio.
        return NoteDocument(file: file, url: URL(fileURLWithPath: "/dev/null")).makeFile()
    }

    private static func documentTitle(_ document: PDFDocument) -> String? {
        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : nil
    }

    private static func startsWithTitle(_ elements: [PDFStructure.Element]) -> Bool {
        if case .heading(1, _)? = elements.first { return true }
        return false
    }

    private static func isText(_ element: PDFStructure.Element) -> Bool {
        switch element {
        case .image, .blankLine: return false
        default: return true
        }
    }
}

/// Turns PDF elements into note blocks: text runs into one text block until a picture comes.
@MainActor
struct PDFNoteBuilder {
    private let theme: ThemeManager
    private var text = NSMutableAttributedString()
    private(set) var blocks: [BlockRecord] = []
    private(set) var attachments: [FolioArchive.Attachment] = []
    private var pictures = 0

    init(theme: ThemeManager) { self.theme = theme }

    mutating func addTitle(_ title: String) { line([PDFStructure.Run(text: title)], style: .title) }
    mutating func addParagraph(_ runs: [PDFStructure.Run]) { line(runs, style: nil) }

    mutating func add(_ element: PDFStructure.Element) {
        switch element {
        case .heading(let level, let runs): line(runs, style: level == 1 ? .title : level == 2 ? .heading : .subheading)
        case .paragraph(let runs): line(runs, style: nil)
        case .listItem(let runs): line(Self.folioListItem(runs), style: nil)
        case .image(let png, _, _): addPicture(png)
        case .blankLine: line([], style: nil)
        }
    }

    /// Folio writes list items as "• Text"; dashes and squares from the PDF become the same bullet.
    static func folioListItem(_ runs: [PDFStructure.Run]) -> [PDFStructure.Run] {
        guard var first = runs.first, let marker = first.text.first, "–▪◦-".contains(marker) else { return runs }
        first.text = "• " + first.text.dropFirst().drop { $0 == " " }
        return [first] + runs.dropFirst()
    }

    private mutating func line(_ runs: [PDFStructure.Run], style: TextStyle?) {
        let base = style?.attributes(theme: theme) ?? theme.bodyAttributes
        if text.length > 0 { text.append(NSAttributedString(string: "\n", attributes: base)) }
        for run in runs { text.append(NSAttributedString(string: run.text, attributes: attributes(base, run))) }
    }

    private func attributes(_ base: [NSAttributedString.Key: Any], _ run: PDFStructure.Run) -> [NSAttributedString.Key: Any] {
        guard var font = base[.font] as? NSFont else { return base }
        if run.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if run.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var attrs = base
        attrs[.font] = font
        return attrs
    }

    private mutating func flushText() {
        guard text.length > 0 else { return }
        var block = BlockRecord(kind: .text)
        block.rtf = RichTextCodec.rtfData(from: text)
        blocks.append(block)
        text = NSMutableAttributedString()
    }

    private mutating func addPicture(_ png: Data) {
        pictures += 1
        addAttachmentBlock(.image, FolioArchive.Attachment(filename: "Bild \(pictures).png", typeIdentifier: UTType.png.identifier, data: png))
    }

    mutating func addAttachmentBlock(_ kind: BlockKind, _ attachment: FolioArchive.Attachment) {
        flushText()
        attachments.append(attachment)
        var block = BlockRecord(kind: kind)
        block.attachmentID = attachment.id
        if kind == .image { block.width = 1 }
        if kind == .pdf { block.pdfText = PDFSearchText.of(attachment.data) }
        blocks.append(block)
    }
}

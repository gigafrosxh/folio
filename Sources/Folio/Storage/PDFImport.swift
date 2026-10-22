import AppKit
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

    static func note(fromPDFAt url: URL) throws -> NoteFile {
        let data = try Data(contentsOf: url)
        let pdf = try PDFText.extract(from: data)
        let theme = ThemeManager.shared
        let fileTitle = url.deletingPathExtension().lastPathComponent
        let title = pdf.title ?? fileTitle
        let text = NSMutableAttributedString(string: title, attributes: TextStyle.title.attributes(theme: theme))
        let body = theme.bodyAttributes
        if pdf.isEmpty {
            text.append(NSAttributedString(string: "\nDiese PDF enthält keinen auswählbaren Text (z. B. ein Scan). Sie ist unten angehängt.", attributes: body))
        } else {
            for (i, page) in pdf.pages.enumerated() where !page.isEmpty {
                if pdf.pages.count > 1 {
                    text.append(NSAttributedString(string: "\nSeite \(i + 1)", attributes: TextStyle.subheading.attributes(theme: theme)))
                }
                text.append(NSAttributedString(string: "\n" + page, attributes: body))
            }
            if pdf.pages.count < pdf.pageCount {
                text.append(NSAttributedString(string: "\n… gekürzt – der vollständige Text steht in der angehängten PDF.", attributes: body))
            }
        }
        var textBlock = BlockRecord(kind: .text)
        textBlock.rtf = RichTextCodec.rtfData(from: text)
        let attachment = FolioArchive.Attachment(filename: url.lastPathComponent, typeIdentifier: UTType.pdf.identifier, data: data)
        var pdfBlock = BlockRecord(kind: .pdf)
        pdfBlock.attachmentID = attachment.id
        var meta = NoteMetadata(title: String(title.prefix(120)))
        meta.searchText = text.string
        meta.preview = String(pdf.pages.first(where: { !$0.isEmpty })?.prefix(200) ?? "")
        meta.kinds = ["text", "pdf"]
        return NoteFile(meta: meta, body: NoteBody(blocks: [textBlock, pdfBlock]), attachments: [attachment])
    }
}

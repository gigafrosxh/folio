import AppKit
import PDFKit
import XCTest
import FolioCore
@testable import Folio

/// Alt text, image edits, PDF search text and PDF annotations in the app (1.5.0: #43–#46).
@MainActor
final class MediaAppTests: XCTestCase {
    private func pdf(_ text: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        ctx.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    private var png: Data {
        let image = NSImage(size: NSSize(width: 8, height: 4), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    func testImageFieldsSurviveSavingAndUndo() {
        let block = BlockModel(kind: .image)
        block.altText = "Diagramm der Zellteilung"
        block.imageEdit = ImageEdit(quarterTurns: 1)
        let r = block.record()
        XCTAssertEqual(r.altText, "Diagramm der Zellteilung")
        XCTAssertEqual(r.imageEdit, ImageEdit(quarterTurns: 1))
        let back = BlockModel(record: r)
        XCTAssertEqual(back.altText, block.altText)
        XCTAssertEqual(back.imageEdit, block.imageEdit)
        XCTAssertTrue(back.plainText.contains("Zellteilung"), "the search finds the alt text")
        let before = BlockModel(kind: .image).record()
        back.apply(before)
        XCTAssertEqual(back.altText, "")
        XCTAssertNil(back.imageEdit, "undo restores both")
    }

    func testMarkdownUsesAltTextAndTheEditedPicture() {
        let att = FolioArchive.Attachment(filename: "Bild.jpg", typeIdentifier: "public.png", data: png)
        var b = BlockRecord(kind: .image)
        b.attachmentID = att.id
        b.caption = "Unterschrift"
        b.altText = "Rotes [Quadrat]"
        b.imageEdit = ImageEdit(quarterTurns: 1)
        let file = NoteFile(meta: NoteMetadata(title: "T"), body: NoteBody(blocks: [b]), attachments: [att])
        let (md, files) = MarkdownTransfer.markdown(for: file, filesFolder: "T Dateien")
        XCTAssertTrue(md.contains("![Rotes (Quadrat)](T%20Dateien/Bild.png)"), md)
        let exported = try? XCTUnwrap(NSImage(data: files[0].1.data))
        XCTAssertEqual(exported?.size.width, 4, "the exported picture is turned")
        b.altText = nil
        let plain = NoteFile(meta: NoteMetadata(title: "T"), body: NoteBody(blocks: [b]), attachments: [att])
        XCTAssertTrue(MarkdownTransfer.markdown(for: plain, filesFolder: "D").0.contains("![Unterschrift]"), "without alt text the caption")
    }

    func testOpenNoteIndexesItsPDFWithoutNewDate() async throws {
        let att = FolioArchive.Attachment(filename: "Skript.pdf", typeIdentifier: "com.adobe.pdf", data: pdf("Mitochondrien sind Kraftwerke"))
        var block = BlockRecord(kind: .pdf)
        block.attachmentID = att.id
        let date = Date(timeIntervalSince1970: 5_000)
        let doc = NoteDocument(file: NoteFile(meta: NoteMetadata(title: "Bio", modified: date), body: NoteBody(blocks: [block]), attachments: [att]),
                               url: URL(fileURLWithPath: "/dev/null"))
        doc.indexPDFs()
        for _ in 0..<40 where doc.blocks.first(where: { $0.kind == .pdf })?.pdfText == nil { try await Task.sleep(for: .milliseconds(50)) }
        let file = doc.makeFile()
        XCTAssertTrue(file.meta.searchText.contains("Mitochondrien"))
        XCTAssertEqual(file.meta.modified, date, "indexing alone does not change the date")
        doc.replaceAttachmentData(att.id, data: pdf("Ribosomen"))
        XCTAssertNil(doc.blocks.first { $0.kind == .pdf }?.pdfText, "new content is indexed again")
    }

    func testHighlightCommentAndRemove() throws {
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.document = PDFDocument(data: pdf("Wichtiger Satz zum Markieren"))
        let controller = PDFAnnotationController()
        controller.view = view
        XCTAssertFalse(controller.highlightSelection(), "nothing selected")
        view.setCurrentSelection(view.document?.findString("Wichtiger", withOptions: []).first, animate: false)
        XCTAssertTrue(controller.highlightSelection())
        XCTAssertTrue(controller.addComment("Prüfungsrelevant"))
        let stored = try XCTUnwrap(controller.data)
        let reopened = try XCTUnwrap(PDFDocument(data: stored)?.page(at: 0))
        let types = reopened.annotations.compactMap(\.type)
        XCTAssertTrue(types.contains("Highlight"), "\(types)")
        XCTAssertTrue(reopened.annotations.contains { $0.contents == "Prüfungsrelevant" }, "the comment is in the saved PDF")
        XCTAssertTrue(reopened.string?.contains("Wichtiger Satz") == true, "the text stays")
        view.clearSelection()
        XCTAssertEqual(controller.removeAnnotations(), 2, "without a selection: everything on the visible page")
        XCTAssertTrue(PDFDocument(data: controller.data!)!.page(at: 0)!.annotations.isEmpty)
    }
}

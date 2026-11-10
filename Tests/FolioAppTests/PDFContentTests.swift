import AppKit
import XCTest
import FolioCore
@testable import Folio

/// What ends up in the exported PDF for each kind of block (#144).
@MainActor
final class PDFContentTests: XCTestCase {
    private func content(_ blocks: [BlockRecord], attachments: [FolioArchive.Attachment] = [], includeOutputs: Bool = true) async -> NSAttributedString {
        let file = NoteFile(meta: NoteMetadata(title: "T"), body: NoteBody(blocks: blocks), attachments: attachments)
        let doc = NoteDocument(file: file, url: URL(fileURLWithPath: "/dev/null"))
        return await NotePDFExporter.buildContent(doc, width: 400, maxImageHeight: 600, options: .init(includeOutputs: includeOutputs))
    }

    private func block(_ kind: BlockKind, _ edit: (inout BlockRecord) -> Void = { _ in }) -> BlockRecord {
        var b = BlockRecord(kind: kind)
        edit(&b)
        return b
    }

    private func text(_ string: String) -> BlockRecord {
        block(.text) { $0.rtf = RichTextCodec.rtfData(from: NSAttributedString(string: string, attributes: ThemeManager.shared.bodyAttributes)) }
    }

    private var png: Data {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in NSColor.blue.setFill(); rect.fill(); return true }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    private func attachmentCount(_ s: NSAttributedString) -> Int {
        var n = 0
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { v, _, _ in if v != nil { n += 1 } }
        return n
    }

    func testTextListsAndSpecialCharacters() async {
        let s = await content([text("Größe 😀\n• Punkt\n☐ Offen"), text(""), text("Zweiter\n")])
        XCTAssertEqual(s.string, "Größe 😀\n• Punkt\n☐ Offen\nZweiter")
    }

    func testCodeWithOutput() async {
        let code = block(.code) { $0.language = "python"; $0.code = "print(1)"; $0.output = "1\n" }
        let shown = await content([code])
        XCTAssertEqual(shown.string, "⌘  Python\nprint(1)\n\n▸  Ausgabe\n1")
        let hidden = await content([code], includeOutputs: false)
        XCTAssertEqual(hidden.string, "⌘  Python\nprint(1)")
    }

    func testCodeErrorIsLabelled() async {
        let s = await content([block(.code) { $0.language = "python"; $0.code = "x"; $0.output = "Boom"; $0.outputIsError = true }])
        XCTAssertTrue(s.string.contains("▸  Fehler\nBoom"), s.string)
    }

    func testDatabaseAndWeb() async {
        let s = await content([block(.database) { $0.code = "select 1" }, block(.web) { $0.url = "https://e.example"; $0.caption = "Titel" }, block(.web)])
        XCTAssertEqual(s.string, "⛁  SQL\nselect 1\n\n🔗 https://e.example\nTitel")
        let link = s.attribute(.link, at: (s.string as NSString).range(of: "https").location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "https://e.example")
    }

    func testImageWithCaptionAndMissingImage() async {
        let attachment = FolioArchive.Attachment(filename: "a.png", typeIdentifier: "public.png", data: png)
        let s = await content([block(.image) { $0.attachmentID = attachment.id; $0.caption = "Bild" }, block(.image) { $0.attachmentID = UUID(); $0.caption = "Fehlt" }],
                              attachments: [attachment])
        XCTAssertEqual(attachmentCount(s), 1)
        XCTAssertTrue(s.string.hasSuffix("Bild"), s.string)
        XCTAssertFalse(s.string.contains("Fehlt"))
    }

    func testAudioWithTranscript() async {
        let s = await content([block(.audio) { $0.output = "Gesagt" }])
        XCTAssertEqual(s.string, "🔊  Audioaufnahme\nGesagt")
    }

    func testEmptyMathIsSkipped() async {
        let s = await content([block(.math) { $0.code = "  " }, block(.diagram)])
        XCTAssertEqual(s.string, "")
    }
}

import AppKit
import XCTest
import FolioCore
@testable import Folio

/// List handling and paste routing of the note text view (#145).
@MainActor
final class TextInputRegressionTests: XCTestCase {
    private var undo: UndoManager!

    private func makeView(_ text: String = "") -> FolioTextView {
        let tv = FolioTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.isRichText = true
        tv.allowsUndo = true
        tv.bodyAttributes = { ThemeManager.shared.bodyAttributes }
        tv.typingAttributes = ThemeManager.shared.bodyAttributes
        tv.string = text
        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return tv
    }

    private func pasteboard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("folio-test-\(UUID().uuidString)"))
        pb.clearContents()
        fill(pb)
        return pb
    }

    func testReturnContinuesBulletList() {
        let tv = makeView("• Eins")
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "• Eins\n• ")
    }

    func testReturnKeepsIndentAndCountsNumberedList() {
        let tv = makeView("\t3. Drei")
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "\t3. Drei\n\t4. ")
    }

    func testReturnContinuesChecklistUnchecked() {
        let tv = makeView("☑ Fertig")
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "☑ Fertig\n☐ ")
    }

    func testReturnOnEmptyItemEndsList() {
        let tv = makeView("• Eins\n• ")
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "• Eins\n")
    }

    func testReturnOnEmbedLineAsksForEmbedBlock() {
        let tv = makeView("![[Andere]]")
        var received: String?
        let token = NotificationCenter.default.addObserver(forName: .folioInsert, object: nil, queue: nil) { received = $0.object as? String }
        defer { NotificationCenter.default.removeObserver(token) }
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "")
        XCTAssertEqual(received, "embed:Andere")
    }

    func testReturnAfterTitleStartsHeadingOrBody() {
        let tv = makeView("Titel")
        tv.isFirstBlock = true
        tv.insertNewline(nil)
        XCTAssertEqual(tv.typingAttributes[.font] as? NSFont, ThemeManager.shared.bodyAttributes[.font] as? NSFont)
    }

    func testFilesGoToTheFileHandler() {
        let tv = makeView()
        var files: [URL] = []
        tv.onPasteFiles = { files = $0; return true }
        let url = URL(fileURLWithPath: "/tmp/a.txt")
        XCTAssertTrue(tv.handlePasteboard(pasteboard { $0.writeObjects([url as NSURL]) }))
        XCTAssertEqual(files, [url])
    }

    func testRejectedFilesFallThrough() {
        let tv = makeView()
        tv.onPasteFiles = { _ in false }
        XCTAssertFalse(tv.handlePasteboard(pasteboard { $0.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL]) }))
    }

    private var pngData: Data {
        let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    func testImageWithLinkAsTextIsAnImage() {
        let tv = makeView()
        var images = 0
        tv.onPasteImage = { _ in images += 1 }
        let png = pngData
        XCTAssertTrue(tv.handlePasteboard(pasteboard { pb in
            pb.declareTypes([.png, .string], owner: nil)
            pb.setData(png, forType: .png)
            pb.setString("https://e.example/a.png", forType: .string)
        }))
        XCTAssertEqual(images, 1)
    }

    func testImageNextToRealTextStaysText() {
        let tv = makeView()
        var images = 0
        tv.onPasteImage = { _ in images += 1 }
        let png = pngData
        XCTAssertFalse(tv.handlePasteboard(pasteboard { pb in
            pb.declareTypes([.png, .string], owner: nil)
            pb.setData(png, forType: .png)
            pb.setString("Ein ganzer Satz", forType: .string)
        }))
        XCTAssertEqual(images, 0)
    }

    func testRichTextWithPicturesSplitsTextAndImages() throws {
        let tv = makeView()
        var images = 0
        tv.onPasteImage = { _ in images += 1 }
        let attachment = NSTextAttachment(fileWrapper: FileWrapper(regularFileWithContents: pngData))
        attachment.fileWrapper?.preferredFilename = "a.png"
        let rich = NSMutableAttributedString(string: "Vor")
        rich.append(NSAttributedString(attachment: attachment))
        let rtfd = try XCTUnwrap(rich.rtfd(from: NSRange(location: 0, length: rich.length)))
        XCTAssertTrue(tv.handlePasteboard(pasteboard { pb in
            pb.declareTypes([.rtfd], owner: nil)
            pb.setData(rtfd, forType: .rtfd)
        }))
        XCTAssertEqual(images, 1)
        XCTAssertEqual(tv.string, "Vor")
    }

    func testURLOnEmptyLineBecomesLinkBlock() {
        let tv = makeView()
        var urls: [URL] = []
        tv.onPasteURL = { urls.append($0); return true }
        XCTAssertTrue(tv.handlePasteboard(pasteboard { $0.setString(" https://e.example/x ", forType: .string) }))
        XCTAssertTrue(tv.handlePasteboard(pasteboard { $0.setString("localhost:3000", forType: .string) }))
        XCTAssertEqual(urls.map(\.absoluteString), ["https://e.example/x", "http://localhost:3000"])
    }

    func testURLInsideATextLineStaysText() {
        let tv = makeView("Text")
        tv.onPasteURL = { _ in XCTFail("kein Link-Block erwartet"); return true }
        XCTAssertFalse(tv.handlePasteboard(pasteboard { $0.setString("https://e.example/x", forType: .string) }))
    }

    func testOtherSchemesAndMultilineTextStayText() {
        let tv = makeView()
        tv.onPasteURL = { _ in XCTFail("kein Link-Block erwartet"); return true }
        XCTAssertFalse(tv.handlePasteboard(pasteboard { $0.setString("ftp://e.example/x", forType: .string) }))
        XCTAssertFalse(tv.handlePasteboard(pasteboard { $0.setString("Eine\nZweite", forType: .string) }))
    }
}

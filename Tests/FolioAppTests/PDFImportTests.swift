import AppKit
import XCTest
@testable import Folio
import FolioCore

/// PDF files become notes with their text and the original attached (#130).
@MainActor
final class PDFImportTests: XCTestCase {
    private func writePDF(_ pages: [String], title: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("folio-pdf-\(UUID().uuidString.prefix(6)).pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 500)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary)!
        for text in pages {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)]).draw(in: CGRect(x: 20, y: 20, width: 360, height: 460))
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    func testPDFBecomesNoteWithTextAndAttachment() throws {
        let url = try writePDF(["Einleitung zum Bericht.", "Ergebnisse auf Seite zwei."], title: "Quartalsbericht")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try PDFImport.note(fromPDFAt: url)
        XCTAssertEqual(file.meta.title, "Quartalsbericht")
        XCTAssertTrue(file.meta.searchText.contains("Ergebnisse auf Seite zwei."), "the text is searchable")
        XCTAssertEqual(file.body.blocks.map(\.kind), [.text, .pdf])
        XCTAssertEqual(file.attachments.first?.data, try Data(contentsOf: url), "the original PDF is kept")
        XCTAssertEqual(file.body.blocks[1].attachmentID, file.attachments.first?.id)
        // Round trip through the file format.
        let back = try NoteFile.decode(file.encoded())
        XCTAssertEqual(back.attachments.count, 1)
    }

    func testScanWithoutTextUsesFileNameAndSaysSo() throws {
        let url = try writePDF([""], title: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try PDFImport.note(fromPDFAt: url)
        XCTAssertEqual(file.meta.title, url.deletingPathExtension().lastPathComponent)
        XCTAssertTrue(file.meta.searchText.contains("keinen auswählbaren Text"))
    }

    func testNotAPDFFails() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kaputt-\(UUID().uuidString.prefix(6)).pdf")
        try Data("kein pdf".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try PDFImport.note(fromPDFAt: url))
    }
}

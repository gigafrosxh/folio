import AppKit
import PDFKit
import XCTest
@testable import FolioCore

/// Text from PDFs for the import (#130).
final class PDFTextTests: XCTestCase {
    /// A small PDF with real text, drawn like any document app would.
    private func makePDF(pages: [String], title: String? = nil) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 500)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        let ctx = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary)!
        for text in pages {
            ctx.beginPDFPage(nil)
            let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
                .draw(in: CGRect(x: 20, y: 20, width: 360, height: 460))
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    func testExtractsTitleAndPages() throws {
        let pdf = makePDF(pages: ["Erste Seite mit Text.", "Zweite Seite."], title: "Bericht 2026")
        let r = try PDFText.extract(from: pdf)
        XCTAssertEqual(r.title, "Bericht 2026")
        XCTAssertEqual(r.pageCount, 2)
        XCTAssertTrue(r.pages[0].contains("Erste Seite mit Text."))
        XCTAssertTrue(r.pages[1].contains("Zweite Seite."))
        XCTAssertFalse(r.isEmpty)
    }

    func testEmptyAndBrokenFiles() throws {
        XCTAssertTrue(try PDFText.extract(from: makePDF(pages: [""])).isEmpty, "a scan has no text")
        XCTAssertThrowsError(try PDFText.extract(from: Data("kein pdf".utf8)))
    }

    func testReflowJoinsBrokenLines() {
        let raw = "Das ist ein langer Satz, der in der PDF\numbricht und mit Bei-\nspiel endet.\n\nNeuer Absatz:\n• Punkt eins\n• Punkt zwei\n1. Erstens"
        XCTAssertEqual(PDFText.reflow(raw),
                       "Das ist ein langer Satz, der in der PDF umbricht und mit Beispiel endet.\nNeuer Absatz:\n• Punkt eins\n• Punkt zwei\n1. Erstens")
        XCTAssertEqual(PDFText.reflow("Nord-\nSüd-Achse"), "Nord-Süd-Achse", "a hyphen before a capital stays")
    }
}

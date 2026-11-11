import AppKit
import XCTest
import PDFKit
@testable import FolioCore
@testable import Folio

/// PDFs with headings, lists, running headers and pictures become structured notes (#167).
@MainActor
final class PDFStructureImportTests: XCTestCase {
    private enum Piece {
        case text(String, CGFloat, bold: Bool)
        case picture(CGFloat)
    }

    /// Draws the pieces top to bottom; every page gets a small running title and its page number.
    private func writePDF(_ pages: [[Piece]]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("folio-struct-\(UUID().uuidString.prefix(6)).pdf")
        var box = CGRect(x: 0, y: 0, width: 500, height: 700)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for (n, pieces) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            var y: CGFloat = 690
            func draw(_ s: String, size: CGFloat, bold: Bool = false, at top: CGFloat) -> CGFloat {
                let a = NSAttributedString(string: s, attributes: [.font: NSFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size)!])
                let h = a.boundingRect(with: CGSize(width: 440, height: 1000), options: [.usesLineFragmentOrigin]).height
                a.draw(with: CGRect(x: 30, y: top - h, width: 440, height: h), options: [.usesLineFragmentOrigin])
                return top - h - 6
            }
            y = draw("Laufende Kopfzeile", size: 7, at: y)
            for piece in pieces {
                switch piece {
                case .text(let s, let size, let bold): y = draw(s, size: size, bold: bold, at: y)
                case .picture(let height):
                    let image = NSImage(size: NSSize(width: 200, height: height), flipped: false) { r in NSColor.systemTeal.setFill(); r.fill(); return true }
                    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
                    ctx.draw(cg, in: CGRect(x: 30, y: y - height, width: 200, height: height))
                    y -= height + 6
                }
            }
            _ = draw("\(n + 1)", size: 7, at: 30)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    private let longText = "Dieser Absatz ist lang genug, dass er im PDF über mehrere Zeilen umbricht, und genau diese Zeilen soll der Import wieder zu einem einzigen Absatz zusammenfügen, ohne etwas zu verlieren."

    private func structure(_ url: URL) -> [PDFStructure.Element] {
        PDFStructure.elements(of: PDFStructure.pages(of: PDFDocument(url: url)!))
    }

    func testHeadingsParagraphsListsAndPictures() throws {
        let url = try writePDF([
            [.text("Schwingungen", 26, bold: true), .text(longText, 12, bold: false), .text("Beispiele", 18, bold: true),
             .text("• Ein Pendel\n• Eine Saite", 12, bold: false), .picture(80), .text("Nach dem Bild", 12, bold: false)],
            [.text("Arten", 15, bold: true), .text("f = 1 / T\nT = 1 / f", 12, bold: false)],
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let elements = structure(url)
        let kinds = elements.map { element -> String in
            switch element {
            case .heading(let level, let runs): return "h\(level) " + runs.map(\.text).joined()
            case .paragraph(let runs): return "p " + runs.map(\.text).joined()
            case .listItem(let runs): return "li " + runs.map(\.text).joined()
            case .image: return "bild"
            case .blankLine: return "leer"
            }
        }
        XCTAssertEqual(kinds, ["h1 Schwingungen", "p " + longText, "h2 Beispiele", "li • Ein Pendel", "li • Eine Saite", "bild",
                               "p Nach dem Bild", "h3 Arten", "p f = 1 / T", "p T = 1 / f"], "\(kinds)")
        guard case .heading(_, let runs) = elements[0] else { return XCTFail() }
        XCTAssertTrue(runs[0].bold)
    }

    func testRunningHeaderAndPageNumbersAreDropped() throws {
        let url = try writePDF([[.text("Erste Seite", 12, bold: false)], [.text("Zweite Seite", 12, bold: false)]])
        defer { try? FileManager.default.removeItem(at: url) }
        let text = structure(url).map { "\($0)" }.joined()
        XCTAssertFalse(text.contains("Laufende Kopfzeile"))
        XCTAssertTrue(text.contains("Erste Seite") && text.contains("Zweite Seite"))
    }

    func testNoteGetsBlocksInOrderAndKeepsThePDF() throws {
        let url = try writePDF([[.text("Titel", 26, bold: true), .text("Vorher steht ein ganzer Satz.", 12, bold: false), .picture(80), .text("Nachher folgt noch ein Satz.", 12, bold: false)]])
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try PDFImport.note(fromPDFAt: url)
        XCTAssertEqual(file.meta.title, "Titel")
        XCTAssertEqual(Array(file.body.blocks.map(\.kind).prefix(4)), [.text, .image, .text, .pdf])
        // The order of stored attachments is not fixed; blocks refer to them by id.
        XCTAssertEqual(Set(file.attachments.map(\.header.typeIdentifier)), ["public.png", "com.adobe.pdf"])
        let picture = try XCTUnwrap(file.attachments.first { $0.id == file.body.blocks[1].attachmentID })
        XCTAssertEqual(picture.header.typeIdentifier, "public.png")
        XCTAssertNotNil(NSImage(data: picture.data))
        let first = RichTextCodec.attributedString(from: file.body.blocks[0].rtf).string
        XCTAssertEqual(first, "Titel\nVorher steht ein ganzer Satz.")
    }

    func testLigaturesAndCleaning() {
        XCTAssertEqual(PDFStructure.cleaned("Begri\u{FB00}e \u{FB01}nden\r\n"), "Begriffe finden")
        XCTAssertTrue(PDFStructure.startsNewLine(after: "7,8 s", before: "Ges.:"))
        XCTAssertFalse(PDFStructure.startsNewLine(after: "eine ", before: "Ruhelage"))
        XCTAssertTrue(PDFStructure.startsWithSubscript("ₐ = 80 kg"))
        XCTAssertEqual(PDFNoteBuilder.folioListItem([PDFStructure.Run(text: "– Punkt")]).first?.text, "• Punkt")
    }
}

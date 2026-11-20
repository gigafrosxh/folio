import AppKit
import XCTest

@testable import Folio

/// #357: pasted rich text keeps size, weight, slant and chosen colours, takes Folio's typeface and text colour.
@MainActor
final class PasteStyleTests: XCTestCase {
    private let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor]

    private func html(_ s: String) -> NSAttributedString {
        NSAttributedString(html: Data(s.utf8), documentAttributes: nil)!
    }

    func testWebTextKeepsLookButTakesFolioFontAndTextColor() {
        let source = html(#"<p style="font-family: Georgia; font-size: 20px; color: #000">Schwarz <b>fett</b> <i>kursiv</i> <span style="color: #d33">rot</span></p>"#)
        let out = PasteStyle.adopt(source, body: body)
        let s = out.string as NSString
        func attrs(_ word: String) -> [NSAttributedString.Key: Any] { out.attributes(at: s.range(of: word).location, effectiveRange: nil) }
        let plain = attrs("Schwarz")
        XCTAssertEqual(plain[.foregroundColor] as? NSColor, .textColor, "Schwarz der Seite wird Folios Textfarbe")
        let font = plain[.font] as! NSFont
        XCTAssertEqual(font.familyName, NSFont.systemFont(ofSize: 14).familyName, "Folio-Schrift statt Georgia")
        XCTAssertEqual(font.pointSize, (source.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, accuracy: 0.1, "Größe bleibt")
        XCTAssertTrue((attrs("fett")[.font] as! NSFont).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue((attrs("kursiv")[.font] as! NSFont).fontDescriptor.symbolicTraits.contains(.italic))
        let red = (attrs("rot")[.foregroundColor] as! NSColor).usingColorSpace(.sRGB)!
        XCTAssertGreaterThan(red.redComponent, 0.7, "gewählte Farbe bleibt")
    }

    func testCodeStaysMonospacedAndWhiteBackgroundGoes() {
        let source = html(#"<p style="background-color: #fff">Text <code>let x = 1</code></p>"#)
        let out = PasteStyle.adopt(source, body: body)
        let s = out.string as NSString
        let code = out.attribute(.font, at: s.range(of: "let").location, effectiveRange: nil) as! NSFont
        XCTAssertTrue(code.isFixedPitch)
        XCTAssertNil(out.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }

    func testPlainColors() {
        XCTAssertTrue(PasteStyle.isPlainTextColor(.black))
        XCTAssertTrue(PasteStyle.isPlainTextColor(.white))
        XCTAssertFalse(PasteStyle.isPlainTextColor(.systemBlue))
        XCTAssertFalse(PasteStyle.isPlainTextColor(NSColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: 1)))
    }

    /// #361: the real paste keeps size, bold and italics (insertText used to replace the fonts) and can be undone.
    func testPasteKeepsSizeBoldAndItalic() throws {
        let tv = FolioTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.isRichText = true
        tv.allowsUndo = true
        tv.bodyAttributes = { ThemeManager.shared.bodyAttributes }
        let window = NSWindow(contentRect: tv.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = tv
        let pb = NSPasteboard(name: NSPasteboard.Name("folio-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setData(Data(#"<p style="font-family: Georgia; font-size: 24px; color: #000">Gross <b>fett</b> <i>kursiv</i></p>"#.utf8), forType: .html)
        pb.setString("Gross fett kursiv", forType: .string)
        tv.paste(from: pb)
        pb.releaseGlobally()
        let storage = try XCTUnwrap(tv.textStorage)
        let s = storage.string as NSString
        func font(_ word: String) -> NSFont? { storage.attribute(.font, at: s.range(of: word).location, effectiveRange: nil) as? NSFont }
        let expected = try XCTUnwrap(html(#"<p style="font-size: 24px">x</p>"#).attribute(.font, at: 0, effectiveRange: nil) as? NSFont).pointSize
        XCTAssertEqual(font("Gross")?.pointSize ?? 0, expected, accuracy: 0.1, "Größe bleibt")
        XCTAssertTrue(font("fett")?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertTrue(font("kursiv")?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .textColor)
        XCTAssertEqual(tv.selectedRange().location, storage.length, "Cursor hinter dem eingefügten Text")
        tv.undoManager?.undo()
        XCTAssertFalse(tv.string.contains("Gross"), "Einfügen lässt sich rückgängig machen")
    }
}

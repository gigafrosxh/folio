import AppKit
import XCTest
@testable import Folio

/// Pasting several lines into the title keeps only the first line as title (#101).
@MainActor
final class PasteTitleTests: XCTestCase {
    private func makeTitleView() -> FolioTextView {
        let tv = FolioTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.isRichText = true
        tv.isFirstBlock = true
        tv.bodyAttributes = { ThemeManager.shared.bodyAttributes }
        tv.typingAttributes = TextStyle.title.attributes(theme: ThemeManager.shared)
        return tv
    }

    private func pasteboard(_ text: String) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("folio-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString(text, forType: .string)
        return pb
    }

    private func font(_ tv: NSTextView, at line: Int) -> NSFont? {
        let ns = tv.string as NSString
        var start = 0
        for _ in 0..<line { start = NSMaxRange(ns.paragraphRange(for: NSRange(location: start, length: 0))) }
        return tv.textStorage?.attribute(.font, at: start, effectiveRange: nil) as? NSFont
    }

    func testOnlyFirstPastedLineIsTitle() {
        let tv = makeTitleView()
        let pb = pasteboard("Audit Einkauf\nÄpfel kaufen\nMilch kaufen\n#privat")
        tv.paste(from: pb)
        XCTAssertEqual(tv.string, "Audit Einkauf\nÄpfel kaufen\nMilch kaufen\n#privat")
        let title = TextStyle.title.attributes(theme: ThemeManager.shared)[.font] as? NSFont
        let body = ThemeManager.shared.bodyAttributes[.font] as? NSFont
        XCTAssertEqual(font(tv, at: 0), title)
        for line in 1...3 { XCTAssertEqual(font(tv, at: line), body, "line \(line) is body text") }
        XCTAssertEqual(tv.typingAttributes[.font] as? NSFont, body, "typing goes on as body text")
        pb.releaseGlobally()
    }

    func testSingleLineStaysTitle() {
        let tv = makeTitleView()
        let pb = pasteboard("Nur ein Titel")
        tv.paste(from: pb)
        XCTAssertEqual(font(tv, at: 0), TextStyle.title.attributes(theme: ThemeManager.shared)[.font] as? NSFont)
        pb.releaseGlobally()
    }

    func testPasteBelowTitleIsUnchanged() {
        let tv = makeTitleView()
        tv.insertText("Titel", replacementRange: tv.selectedRange())
        tv.insertNewline(nil)
        let pb = pasteboard("eins\nzwei")
        tv.paste(from: pb)
        let body = ThemeManager.shared.bodyAttributes[.font] as? NSFont
        XCTAssertEqual(font(tv, at: 1), body)
        XCTAssertEqual(font(tv, at: 2), body)
        pb.releaseGlobally()
    }
}

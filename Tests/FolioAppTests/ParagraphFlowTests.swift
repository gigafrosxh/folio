import AppKit
import XCTest
@testable import Folio

/// Paragraph styles follow while typing, and lists format themselves (#125).
@MainActor
final class ParagraphFlowTests: XCTestCase {
    private func makeView(headingAfterTitle: Bool = true) -> FolioTextView {
        let tv = FolioTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        tv.isRichText = true
        tv.isFirstBlock = true
        let theme = ThemeManager.shared
        tv.bodyAttributes = { theme.bodyAttributes }
        tv.styleAttributes = { $0.attributes(theme: theme) }
        tv.headingAfterTitle = { headingAfterTitle }
        tv.typingAttributes = TextStyle.title.attributes(theme: theme)
        return tv
    }

    private func type(_ tv: NSTextView, _ text: String) {
        for ch in text {
            if ch == "\n" { tv.insertNewline(nil) } else { tv.insertText(String(ch), replacementRange: tv.selectedRange()) }
        }
    }

    private func font(_ tv: NSTextView, line: Int) -> NSFont? {
        let ns = tv.string as NSString
        var start = 0
        for _ in 0..<line { start = NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0))) }
        return tv.textStorage?.attribute(.font, at: start, effectiveRange: nil) as? NSFont
    }

    func testTitleThenHeadingThenBody() {
        let tv = makeView()
        type(tv, "Einkauf\nWoche 43\nMilch holen")
        let theme = ThemeManager.shared
        XCTAssertEqual(font(tv, line: 0), TextStyle.title.attributes(theme: theme)[.font] as? NSFont)
        XCTAssertEqual(font(tv, line: 1), TextStyle.heading.attributes(theme: theme)[.font] as? NSFont)
        XCTAssertEqual(font(tv, line: 2), theme.bodyAttributes[.font] as? NSFont)
    }

    func testWithoutHeadingSettingBodyFollowsTitle() {
        let tv = makeView(headingAfterTitle: false)
        type(tv, "Einkauf\nMilch")
        XCTAssertEqual(font(tv, line: 1), ThemeManager.shared.bodyAttributes[.font] as? NSFont)
    }

    func testDashBecomesBulletAndListContinuesWithHangingIndent() {
        let tv = makeView()
        type(tv, "Liste\n\n- eins\nzwei")
        XCTAssertEqual(tv.string, "Liste\n\n• eins\n• zwei")
        type(tv, "\n\n[] offen")   // Return on an empty bullet ends the list
        XCTAssertTrue(tv.string.hasSuffix("\n☐ offen"))
        let ns = tv.string as NSString
        let style = tv.textStorage?.attribute(.paragraphStyle, at: ns.range(of: "• eins").location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThan(style?.headIndent ?? 0, 4, "wrapped lines start under the text")
        XCTAssertEqual(ParagraphFlowTests.firstLineFont(tv), TextStyle.title.attributes(theme: ThemeManager.shared)[.font] as? NSFont)
    }

    private static func firstLineFont(_ tv: NSTextView) -> NSFont? { tv.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont }

    func testDashInTitleStaysText() {
        let tv = makeView()
        type(tv, "- kein Punkt")
        XCTAssertEqual(tv.string, "- kein Punkt")
    }
}

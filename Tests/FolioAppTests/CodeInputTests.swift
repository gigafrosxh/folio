import AppKit
import XCTest
import FolioCore
@testable import Folio

/// Typing into a code block: pairs, stepping over closers, wrapping and dedenting (#141).
@MainActor
final class CodeInputTests: XCTestCase {
    private func makeView(_ text: String = "", caret: Int? = nil, language: String = "swift") -> CodeTextView {
        let tv = CodeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.language = language
        tv.string = text
        tv.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
        return tv
    }

    private func type(_ s: String, into tv: CodeTextView) { tv.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0)) }

    func testBracketGetsItsPartner() {
        let tv = makeView()
        type("(", into: tv)
        XCTAssertEqual(tv.string, "()")
        XCTAssertEqual(tv.selectedRange().location, 1)
    }

    func testTypingTheCloserStepsOverIt() {
        let tv = makeView("()", caret: 1)
        type(")", into: tv)
        XCTAssertEqual(tv.string, "()")
        XCTAssertEqual(tv.selectedRange().location, 2)
    }

    func testSelectionIsWrapped() {
        let tv = makeView("abc")
        tv.setSelectedRange(NSRange(location: 0, length: 3))
        type("[", into: tv)
        XCTAssertEqual(tv.string, "[abc]")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 1, length: 3))
    }

    func testNoPairDirectlyBeforeAWord() {
        let tv = makeView("abc", caret: 0)
        type("(", into: tv)
        XCTAssertEqual(tv.string, "(abc")
    }

    func testQuoteAfterALetterStaysSingle() {
        let tv = makeView("don")
        type("\"", into: tv)
        XCTAssertEqual(tv.string, "don\"")
    }

    func testCloserOnEmptyLineDedents() {
        let tv = makeView("{\n        ")
        type("}", into: tv)
        XCTAssertEqual(tv.string, "{\n    }")
    }

    func testPastedTextIsNotPaired() {
        let tv = makeView()
        type("foo(", into: tv)
        XCTAssertEqual(tv.string, "foo(")
    }

    func testMultilineInsertStaysUnchanged() {
        let tv = makeView()
        type("a\nb", into: tv)
        XCTAssertEqual(tv.string, "a\nb")
    }
}

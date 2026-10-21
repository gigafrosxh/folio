import AppKit
import XCTest
@testable import Folio

/// ⌥⌫ deletes the word before the cursor, but never more than the current line (#129).
@MainActor
final class DeleteWordTests: XCTestCase {
    private func run(_ text: String, cursorAtEnd: Bool = true) -> String {
        let tv = FolioTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.string = text
        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        tv.deleteWordBackward(nil)
        return tv.string
    }

    func testOnlyWhitespaceOnLineDeletesTheWhitespace() {
        XCTAssertEqual(run("Hallo\n "), "Hallo\n")
        XCTAssertEqual(run("Hallo Welt\n   "), "Hallo Welt\n")
    }

    func testAtStartOfLineJoinsWithThePreviousLine() {
        XCTAssertEqual(run("Hallo\n"), "Hallo")
    }

    func testWordsAreDeletedAsUsual() {
        XCTAssertEqual(run("Hallo Welt"), "Hallo ")
        XCTAssertEqual(run("Eins\nZwei drei"), "Eins\nZwei ")
        XCTAssertEqual(run("Eins\nZwei"), "Eins\n", "stops at the line start")
    }
}

import XCTest
@testable import Folio

final class WordLabelTests: XCTestCase {
    func testSingularAndPlural() {
        XCTAssertEqual(NoteStatusPill.wordLabel(0), "0 Wörter")
        XCTAssertEqual(NoteStatusPill.wordLabel(1), "1 Wort")
        XCTAssertEqual(NoteStatusPill.wordLabel(2), "2 Wörter")
    }
}

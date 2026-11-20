import XCTest

@testable import FolioCore

/// #267, #268: overlapping autosaves never write an older snapshot, and edits made meanwhile stay unsaved.
final class SaveRevisionsTests: XCTestCase {
    func testSavesFinishingInReverseOrderKeepNewest() {
        var saves = SaveRevisions()
        // Snapshot A at revision 5, then snapshot B at revision 7; B finishes first.
        XCTAssertTrue(saves.mayWrite(7))
        XCTAssertTrue(saves.didWrite(7, current: 7))
        XCTAssertFalse(saves.mayWrite(5), "älterer Stand überschreibt den neueren nicht")
        XCTAssertEqual(saves.written, 7)
    }

    func testEditDuringSaveStaysDirty() {
        var saves = SaveRevisions()
        XCTAssertFalse(saves.didWrite(3, current: 4), "Eingabe während des Komprimierens bleibt ungesichert")
        XCTAssertTrue(saves.mayWrite(4), "nächstes Sichern schreibt sie")
    }

    func testOpenedStateIsNotRewritten() {
        let saves = SaveRevisions(opened: 0)
        XCTAssertFalse(saves.mayWrite(0))
        XCTAssertTrue(saves.mayWrite(1))
    }
}

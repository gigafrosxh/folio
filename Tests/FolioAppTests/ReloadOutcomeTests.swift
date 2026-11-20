import XCTest

@testable import Folio

/// #362: a background read that began before a note was created, duplicated or deleted must not be applied.
final class ReloadOutcomeTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/bibliothek")

    func testUnchangedLibraryIsApplied() {
        XCTAssertEqual(NoteStore.reloadOutcome(started: (3, 7, root), now: (3, 7, root), attempt: 0), .apply)
    }

    func testNewerReadOrOtherLibraryWins() {
        XCTAssertEqual(NoteStore.reloadOutcome(started: (3, 7, root), now: (4, 7, root), attempt: 0), .drop)
        XCTAssertEqual(NoteStore.reloadOutcome(started: (3, 7, root), now: (3, 7, URL(fileURLWithPath: "/tmp/andere")), attempt: 0), .drop)
    }

    func testChangedListsAreReadAgainThenSynchronously() {
        XCTAssertEqual(NoteStore.reloadOutcome(started: (3, 7, root), now: (3, 8, root), attempt: 0), .readAgain)
        XCTAssertEqual(NoteStore.reloadOutcome(started: (3, 7, root), now: (3, 8, root), attempt: 1), .readAgain)
        XCTAssertEqual(NoteStore.reloadOutcome(started: (3, 7, root), now: (3, 8, root), attempt: 2), .readNow)
    }
}

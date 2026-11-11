import XCTest
@testable import FolioCore

/// Singular and plural in the graph statistics (#165).
final class GraphSummaryTests: XCTestCase {
    func testZeroOneTwo() {
        XCTAssertEqual(GraphSummary(notes: 0, folders: 0, links: 0, orphans: 0).spoken, "0 Notizen, 0 Ordner, 0 Verknüpfungen")
        XCTAssertEqual(GraphSummary(notes: 1, folders: 1, links: 1, orphans: 0).spoken, "1 Notiz, 1 Ordner, 1 Verknüpfung")
        XCTAssertEqual(GraphSummary(notes: 2, folders: 2, links: 2, orphans: 1).legend, "2 Notizen · 2 Ordner · 2 Verknüpfungen · 1 verwaist")
    }

    func testCount() {
        XCTAssertEqual(GermanCount.format(1, "Notiz", "Notizen"), "1 Notiz")
        XCTAssertEqual(GermanCount.format(11, "Notiz", "Notizen"), "11 Notizen")
    }
}

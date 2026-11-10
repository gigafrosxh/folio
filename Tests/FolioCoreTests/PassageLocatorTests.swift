import XCTest
@testable import FolioCore

final class PassageLocatorTests: XCTestCase {
    func testFindsSingleLineIgnoringCaseAndDiacritics() throws {
        let match = try XCTUnwrap(PassageLocator.locate(["uber Baume"], in: "Etwas Über Bäume hier"))
        XCTAssertEqual(match.range, NSRange(location: 6, length: 10))
        XCTAssertEqual(match.firstLineLength, 10)
    }

    func testSelectionReachesToLastLine() throws {
        let text = "x Anfang der Stelle\nMitte\nEnde der Stelle y"
        let match = try XCTUnwrap(PassageLocator.locate(["Anfang der Stelle", "Ende der Stelle"], in: text))
        XCTAssertEqual((text as NSString).substring(with: match.range), "Anfang der Stelle\nMitte\nEnde der Stelle")
        XCTAssertEqual(match.firstLineLength, 17)
    }

    func testFarAwayLastLineIsIgnored() throws {
        let text = "Anfang" + String(repeating: " ", count: 5000) + "Schluss"
        let match = try XCTUnwrap(PassageLocator.locate(["Anfang", "Schluss"], in: text))
        XCTAssertEqual(match.range, NSRange(location: 0, length: 6))
    }

    func testNoMatchAndShortLines() {
        XCTAssertNil(PassageLocator.locate(["fehlt"], in: "Text"))
        XCTAssertNil(PassageLocator.locate([], in: "Text"))
        XCTAssertEqual(PassageLocator.searchLines(of: " ab \n  Zeile  \n\n"), ["Zeile"])
    }
}

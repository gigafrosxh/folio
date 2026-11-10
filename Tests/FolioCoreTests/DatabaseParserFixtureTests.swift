import XCTest
@testable import FolioCore

/// Output of the database command-line tools, including the awkward cases (#148).
final class DatabaseParserFixtureTests: XCTestCase {
    private let s = "\u{001F}"

    func testSQLCMDKeepsLastNonEmptySetAndNull() throws {
        let out = "a\(s)b\n-\(s)-\n1\(s)NULL\nä\(s)x\n\nc\n-\n\n"
        let r = try DatabaseClient.parseSQLCMD(out)
        XCTAssertEqual(r.columns, ["a", "b"])
        XCTAssertEqual(r.rows, [["1", nil], ["ä", "x"]])
    }

    func testSQLCMDJoinsMultilineFieldsAndCRLF() throws {
        let r = try DatabaseClient.parseSQLCMD("a\(s)b\r\n-\(s)-\r\nZeile 1\nZeile 2\(s)y\n")
        XCTAssertEqual(r.rows, [["Zeile 1\nZeile 2", "y"]])
    }

    func testSQLCMDChangeCounts() throws {
        XCTAssertEqual(try DatabaseClient.parseSQLCMD("__folio_changes\n-\n1\n").message, "1 Zeile geändert")
        XCTAssertEqual(try DatabaseClient.parseSQLCMD("__folio_changes\n-\n3\n").message, "3 Zeilen geändert")
        XCTAssertEqual(try DatabaseClient.parseSQLCMD("").message, "Ausgeführt.")
    }

    func testSQLCMDMalformedOutputIsAnError() {
        XCTAssertThrowsError(try DatabaseClient.parseSQLCMD("a\(s)b\n-\(s)-\n1\(s)2\(s)3\n"))
        XCTAssertThrowsError(try DatabaseClient.parseSQLCMD("a\(s)b\n-\(s)-\nnur eins"))
    }

    func testCSVEmptyFieldsQuotesAndSeparators() throws {
        let r = try DatabaseClient.parseCSV("a,b,c\n,\"\",\"x,\"\"y\"\"\nz\"\n\"ü\",😀,\n")
        XCTAssertEqual(r.columns, ["a", "b", "c"])
        XCTAssertEqual(r.rows, [[nil, "", "x,\"y\"\nz"], ["ü", "😀", nil]])
    }

    func testCSVWithNullMarker() throws {
        let r = try DatabaseClient.parseCSV("a,b\nNIL,\n", nullMarker: "NIL")
        XCTAssertEqual(r.rows, [[nil, ""]])
    }

    func testCSVMultipleSetsReturnsLastNonEmpty() throws {
        XCTAssertEqual(try DatabaseClient.parseCSV("a\n1\n\nb\n2\n").rows, [["2"]])
        XCTAssertEqual(try DatabaseClient.parseCSV("a,b\n1,2\nc\n").rows, [["1", "2"]])
        XCTAssertEqual(try DatabaseClient.parseCSV("a\n").columns, ["a"])
        XCTAssertEqual(try DatabaseClient.parseCSV("").message, "Ausgeführt.")
    }

    func testCSVNoFinalNewlineAndUnterminatedQuote() throws {
        XCTAssertEqual(try DatabaseClient.parseCSV("a\r\n1").rows, [["1"]])
        XCTAssertThrowsError(try DatabaseClient.parseCSV("a\n\"offen"))
    }
}

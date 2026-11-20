import Foundation
import XCTest

/// A test that needs an outside tool skips without it, unless the run says the tool must be there:
/// `FOLIO_REQUIRE=python3,psql,postgres,mysql` (or `all`) turns the skip into a failure. The CI sets it for every tool it
/// installs, so nothing that should run is skipped silently (#317).
func skipOrFail(_ reason: String, tool: String) -> Error {
    let required = Set((ProcessInfo.processInfo.environment["FOLIO_REQUIRE"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    if required.contains(tool) || required.contains("all") { return RequiredToolMissing(description: "\(reason) – in diesem Lauf Pflicht (FOLIO_REQUIRE)") }
    return XCTSkip(reason)
}

struct RequiredToolMissing: Error, CustomStringConvertible {
    let description: String
}

final class TestRequirementsTests: XCTestCase {
    func testRequiredToolTurnsSkipIntoFailure() {
        let before = ProcessInfo.processInfo.environment["FOLIO_REQUIRE"]
        defer { if let before { setenv("FOLIO_REQUIRE", before, 1) } else { unsetenv("FOLIO_REQUIRE") } }
        unsetenv("FOLIO_REQUIRE")
        XCTAssertTrue(skipOrFail("fehlt", tool: "foo") is XCTSkip)
        setenv("FOLIO_REQUIRE", "bar, foo", 1)
        XCTAssertTrue(skipOrFail("fehlt", tool: "foo") is RequiredToolMissing)
        XCTAssertTrue(skipOrFail("fehlt", tool: "baz") is XCTSkip)
        setenv("FOLIO_REQUIRE", "all", 1)
        XCTAssertTrue(skipOrFail("fehlt", tool: "baz") is RequiredToolMissing)
    }
}

import XCTest
@testable import FolioCore

final class TestIsolationTests: XCTestCase {
    func testReleaseIdentityRefusesTestMode() {
        XCTAssertNotNil(TestIsolation.refusal(bundleID: "de.daniel.folio", environment: ["FOLIO_LIBRARY": "/tmp/x"]))
        XCTAssertNotNil(TestIsolation.refusal(bundleID: "de.daniel.folio", environment: ["FOLIO_KEY_TEST": "1"]))
    }

    func testNormalStartAndTestCopiesAreAllowed() {
        XCTAssertNil(TestIsolation.refusal(bundleID: "de.daniel.folio", environment: ["PATH": "/usr/bin"]))
        XCTAssertNil(TestIsolation.refusal(bundleID: "de.daniel.folio.selftest", environment: ["FOLIO_LIBRARY": "/tmp/x"]))
        XCTAssertNil(TestIsolation.refusal(bundleID: nil, environment: ["FOLIO_LIBRARY": "/tmp/x"]))
    }
}

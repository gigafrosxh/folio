import XCTest

@testable import Folio

/// #384: render pages never navigate away from Folio's own page.
@MainActor
final class RenderNavigationTests: XCTestCase {
    func testOnlyOwnPageIsAllowed() {
        XCTAssertTrue(RenderNavigationGuard.allows(WebResources.pageURL))
        XCTAssertTrue(RenderNavigationGuard.allows(URL(string: "about:blank")))
        XCTAssertFalse(RenderNavigationGuard.allows(URL(string: "https://example.com")))
        XCTAssertFalse(RenderNavigationGuard.allows(URL(string: "file:///etc/passwd")))
        XCTAssertFalse(RenderNavigationGuard.allows(nil))
    }
}

import XCTest
@testable import FolioCore

final class DropClassifierTests: XCTestCase {
    func testGroups() {
        let urls = ["/a/Notiz.folio", "/a/Bild.PNG", "/a/Plan.pdf", "/a/Ordner", "/a/x.erdu"].map { URL(fileURLWithPath: $0) }
            + [URL(string: "https://example.com")!]
        let g = DropClassifier.classify(urls) { $0.lastPathComponent == "Ordner" }
        XCTAssertEqual(g.notes.map(\.lastPathComponent), ["Notiz.folio"])
        XCTAssertEqual(g.images.map(\.lastPathComponent), ["Bild.PNG"])
        XCTAssertEqual(g.files.map(\.lastPathComponent), ["Plan.pdf", "x.erdu"])
        XCTAssertEqual(g.skipped.map(\.lastPathComponent), ["Ordner"])
    }
}

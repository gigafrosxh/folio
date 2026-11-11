import AppKit
import XCTest
import FolioCore
@testable import Folio

/// Update identity and imported content with untrusted input (#161).
@MainActor
final class SecurityAppTests: XCTestCase {
    func testUpdateVersionMustMatchAndBeNewer() {
        XCTAssertNoThrow(try UpdateManager.verifyVersion("1.3.13", expected: "1.3.13", installed: "1.3.12"))
        XCTAssertThrowsError(try UpdateManager.verifyVersion(nil, expected: "1.3.13", installed: "1.3.12"), "a download without version")
        XCTAssertThrowsError(try UpdateManager.verifyVersion("1.3.14", expected: "1.3.13", installed: "1.3.12"), "another version than announced")
        XCTAssertThrowsError(try UpdateManager.verifyVersion("1.3.1", expected: "1.3.1", installed: "1.3.12"), "a downgrade")
        XCTAssertThrowsError(try UpdateManager.verifyVersion("1.3.12", expected: "1.3.12", installed: "1.3.12"), "the same version again")
    }

    func testUpdateTeamMustStayTheSame() {
        XCTAssertNoThrow(try UpdateManager.verifyTeam(new: nil, installed: nil), "ad-hoc signed today")
        XCTAssertNoThrow(try UpdateManager.verifyTeam(new: "ABCDE12345", installed: nil), "moving to a Developer ID")
        XCTAssertNoThrow(try UpdateManager.verifyTeam(new: "ABCDE12345", installed: "ABCDE12345"))
        XCTAssertThrowsError(try UpdateManager.verifyTeam(new: "ZZZZZ99999", installed: "ABCDE12345"), "another developer")
        XCTAssertThrowsError(try UpdateManager.verifyTeam(new: nil, installed: "ABCDE12345"), "back to ad hoc")
    }

    func testMarkdownLinksWithDangerousSchemesStayText() {
        let s = MarkdownTransfer.attributed(fromMarkdown: "[klick](javascript:alert(1)) [datei](file:///etc/passwd) [web](https://e.example)")
        var links: [String] = []
        s.enumerateAttribute(.link, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if let v { links.append((v as? URL)?.absoluteString ?? "\(v)") }
        }
        XCTAssertEqual(links, ["https://e.example"])
        XCTAssertTrue(s.string.contains("klick") && s.string.contains("datei"), "the text itself stays")
    }

    func testMarkdownImportReadsNoFilesOutsideItsFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folio-mdimp-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Import")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("geheim".utf8).write(to: root.appendingPathComponent("geheim.png"))
        try Data([137, 80, 78, 71]).write(to: folder.appendingPathComponent("gut.png"))
        let note = MarkdownTransfer.note(fromMarkdown: "![a](../geheim.png)\n\n![b](gut.png)\n\n![c](/etc/hosts)\n", title: "T", baseURL: folder)
        XCTAssertEqual(note.attachments.map(\.header.filename), ["gut.png"])
        XCTAssertFalse(note.attachments.contains { $0.data == Data("geheim".utf8) })
    }
}

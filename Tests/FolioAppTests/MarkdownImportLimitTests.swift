import XCTest

@testable import Folio

/// #385: the Markdown import reads only regular files within a size limit.
@MainActor
final class MarkdownImportLimitTests: XCTestCase {
    func testPipesAreSkippedAndNormalFilesEmbedded() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(mkfifo(dir.appendingPathComponent("rohr").path, 0o600), 0)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: dir.appendingPathComponent("bild.png"))
        let md = dir.appendingPathComponent("n.md")
        try "# Titel\n![a](rohr)\n![b](bild.png)\n".write(to: md, atomically: true, encoding: .utf8)
        let start = Date()
        let file = try MarkdownTransfer.note(fromMarkdownAt: md)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "die Pipe blockiert nicht")
        XCTAssertEqual(file.attachments.map(\.header.filename), ["bild.png"])
        XCTAssertThrowsError(try MarkdownTransfer.note(fromMarkdownAt: dir.appendingPathComponent("rohr")))
    }
}

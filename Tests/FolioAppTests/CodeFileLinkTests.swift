import AppKit
import XCTest

@testable import FolioCore
@testable import Folio

/// #326: a failed write of a code block to its file is reported, not dropped.
@MainActor
final class CodeFileLinkTests: XCTestCase {
    func testWriteFailureIsReportedAndSuccessIsNot() throws {
        var record = BlockRecord(kind: .code)
        record.code = "print(1)"
        let doc = NoteDocument(file: NoteFile(meta: NoteMetadata(title: "T"), body: NoteBody(blocks: [record])), url: URL(fileURLWithPath: "/dev/null"))
        let block = try XCTUnwrap(doc.blocks.first)
        let failed = CodeFileLink.write(block, to: URL(fileURLWithPath: "/nicht/vorhanden/\(UUID().uuidString)/main.py"), in: doc)
        XCTAssertTrue(failed.hasPrefix(CodeFileLink.failurePrefix), failed)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ok = CodeFileLink.write(block, to: dir.appendingPathComponent("main.py"), in: doc)
        XCTAssertFalse(ok.hasPrefix(CodeFileLink.failurePrefix), ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("main.py").path))
    }
}

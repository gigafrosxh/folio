import Compression
import XCTest
@testable import FolioCore

/// Negative tests for Folio's trust boundaries (#161): forged note files, links, rendering input and secrets.
final class SecurityRegressionTests: XCTestCase {
    // MARK: Note files

    /// A file whose first section claims `raw` bytes but stores `stored`.
    private func forged(raw: UInt64, stored: Data, attachments: UInt32 = 0) -> Data {
        var w = ByteWriter()
        w.append(FolioArchive.magic)
        w.append(UInt16(FolioArchive.currentVersion))
        w.append(UInt16(1))
        w.append(raw)
        w.append(UInt64(stored.count))
        w.append(stored)
        try? w.appendSection(Data("{}".utf8))
        w.append(attachments)
        w.append(CRC32.checksum(w.data))
        return w.data
    }

    private func lzfse(_ data: Data) -> Data { try! (data as NSData).compressed(using: .lzfse) as Data }

    func testHugeClaimedSectionIsRefusedWithoutUnpacking() {
        let start = Date()
        XCTAssertThrowsError(try FolioArchive.decode(forged(raw: 1 << 40, stored: Data(repeating: 1, count: 100)))) {
            XCTAssertEqual($0 as? FolioFormatError, .tooLarge)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testDecompressionBombIsRefused() {
        let zeros = Data(count: 256 * 1024 * 1024)
        let packed = lzfse(zeros)
        XCTAssertGreaterThan(UInt64(zeros.count), UInt64(packed.count) * ArchiveLimits.maxRatio, "the test data really is a bomb")
        XCTAssertThrowsError(try FolioArchive.decode(forged(raw: UInt64(zeros.count), stored: packed))) {
            XCTAssertEqual($0 as? FolioFormatError, .tooLarge)
        }
    }

    func testSmallerClaimThanContentIsRefused() {
        let text = Data(String(repeating: "Notiz ", count: 2_000).utf8)
        XCTAssertThrowsError(try FolioArchive.decode(forged(raw: 100, stored: lzfse(text))))
    }

    func testImpossibleLengthsDoNotCrash() {
        for raw: UInt64 in [.max, .max - 1, 1 << 63] {
            XCTAssertThrowsError(try FolioArchive.decode(forged(raw: raw, stored: Data([1, 2, 3]))))
        }
        var uncompressed = forged(raw: .max, stored: Data([1]))
        uncompressed[6] = 0   // flags: not compressed
        XCTAssertThrowsError(try FolioArchive.decode(uncompressed))
    }

    func testTooManyAttachmentsAreRefused() {
        XCTAssertThrowsError(try FolioArchive.decode(forged(raw: 2, stored: lzfse(Data("{}".utf8)), attachments: ArchiveLimits.maxAttachments + 1))) {
            XCTAssertEqual($0 as? FolioFormatError, .tooLarge)
        }
    }

    func testLargeRealAttachmentStillWorks() throws {
        var random = Data(count: 8 * 1024 * 1024)
        random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        let file = NoteFile(meta: NoteMetadata(title: "Groß"), body: NoteBody(),
                            attachments: [FolioArchive.Attachment(filename: "a.bin", typeIdentifier: "public.data", data: random)])
        XCTAssertEqual(try NoteFile.decode(file.encoded()).attachments.first?.data, random)
        XCTAssertTrue(ArchiveLimits.allows(raw: 10_000, stored: 5), "small sections are always allowed")
        XCTAssertTrue(ArchiveLimits.allows(raw: 1_000, stored: .max), "a huge stored length does not overflow")
        XCTAssertFalse(ArchiveLimits.allows(raw: .max, stored: .max))
    }

    func testDiagnosisReportsAForgedFile() {
        let report = FolioDiagnostics.diagnose(forged(raw: 1 << 40, stored: Data([1, 2, 3])))
        XCTAssertTrue(report.problems.contains { $0.severity == .error })
    }

    // MARK: Links

    func testOnlyNewNotesChangeTheLibrary() {
        let id = UUID()
        let actions: [FolioAction] = [.openNote(id, passage: 2), .capture(text: "x", target: .note(id)), .search("x"), .open]
        XCTAssertTrue(actions.allSatisfy { !$0.changesLibrary })
        XCTAssertTrue(FolioAction.newNote(title: nil, text: nil).changesLibrary)
    }

    func testHostileFolioLinksAreRejected() {
        let bad = ["folio://note/..%2F..%2Fetc%2Fpasswd", "folio://note/%00", "folio://delete", "folio://capture?target=../../x",
                   "javascript://folio/alert(1)", "folio://search?q=" + String(repeating: "a", count: 100_001)]
        for link in bad {
            guard let url = URL(string: link) else { continue }
            if case .success(let action) = FolioURL.parse(url) { XCTFail("\(link) → \(action)") }
        }
    }

    func testOnlySafeLinkSchemes() {
        for safe in ["https://e.example", "http://localhost:3000", "mailto:a@b.de", "folio://note/x"] { XCTAssertTrue(LinkSafety.isSafe(safe), safe) }
        for unsafe in ["javascript:alert(1)", " JavaScript:alert(1)", "file:///etc/passwd", "data:text/html,x", "vbscript:x", "x-apple-helpviewer://x", "relativ"] {
            XCTAssertFalse(LinkSafety.isSafe(unsafe), unsafe)
        }
    }

    func testFilesOutsideTheImportFolderAreNotRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folio-md-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Import")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Bilder"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("geheim".utf8).write(to: root.appendingPathComponent("geheim.txt"))
        try Data([1]).write(to: folder.appendingPathComponent("Bilder/a.png"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("raus"), withDestinationURL: root)
        XCTAssertNotNil(LinkSafety.fileInside(folder, relativePath: "Bilder/a.png"))
        for path in ["../geheim.txt", "Bilder/../../geheim.txt", "/etc/passwd", root.appendingPathComponent("geheim.txt").path, "raus/geheim.txt", "file:///etc/passwd"] {
            XCTAssertNil(LinkSafety.fileInside(folder, relativePath: path), path)
        }
    }

    // MARK: Rendering

    func testRenderSourceCannotBreakOutOfTheScriptCall() throws {
        let hostile = "\"); alert(1); (\"\n</script><script>alert(2)</script>\u{2028}\\"
        let call = RenderScript.call(.diagram, source: hostile)
        XCTAssertFalse(call.contains("</script"))
        XCTAssertFalse(call.contains("\u{2028}"))
        let literal = RenderScript.jsString(hostile).replacingOccurrences(of: "<\\/", with: "</")
        let decoded = try JSONSerialization.jsonObject(with: Data("[\(literal)]".utf8)) as? [String]
        XCTAssertEqual(decoded, [hostile], "the page receives exactly the text, as a string")
    }

    // MARK: Secrets

    func testPasswordsAreRemovedFromMessages() {
        let env = ["PGPASSWORD": "Sommer2026!", "MYSQL_PWD": "hunter22", "PATH": "/usr/bin", "SQLCMDPASSWORD": "x"]
        let secrets = SecretRedaction.secrets(in: env)
        XCTAssertEqual(Set(secrets), ["Sommer2026!", "hunter22", "x"])
        let message = "FATAL: password authentication failed for user \"u\" (Sommer2026!) mysql -phunter22 x"
        let redacted = SecretRedaction.redact(message, secrets: secrets)
        XCTAssertFalse(redacted.contains("Sommer2026!") || redacted.contains("hunter22"))
        XCTAssertTrue(redacted.hasSuffix(" x"), "too short to be a secret worth hiding")
    }

    func testNoteFilesNeverContainDatabasePasswords() throws {
        var block = BlockRecord(kind: .code)
        block.connection = DatabaseConnection(name: "Prod", driver: .postgresql, host: "db", database: "app", user: "u")
        let data = try JSONEncoder().encode(block)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).lowercased().contains("pass"))
    }
}

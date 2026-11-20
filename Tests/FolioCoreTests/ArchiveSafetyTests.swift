import XCTest

@testable import FolioCore

/// Milestone 1.11.0: archive limits and parsing (#272, #273, #275, #276, #277), metadata (#278), history (#274,
/// #279), backups (#324, #325) and file stamps (#271).
final class ArchiveSafetyTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func note(_ text: String = "Hallo", attachment: String? = nil) -> NoteFile {
        var b = BlockRecord(kind: .code)
        b.code = text
        let atts = attachment.map { [FolioArchive.Attachment(filename: $0, typeIdentifier: "public.data", data: Data("x".utf8))] } ?? []
        return NoteFile(meta: NoteMetadata(title: "T"), body: NoteBody(blocks: [b]), attachments: atts)
    }

    /// Rewrites the checksum so a test can change bytes without tripping it.
    private func resealed(_ payload: Data) -> Data {
        var w = ByteWriter()
        w.append(payload)
        w.append(CRC32.checksum(payload))
        return w.data
    }

    // #272
    func testEncoderRefusesWhatDecoderRefuses() throws {
        var archive = FolioArchive(meta: Data("{}".utf8), body: Data(), attachments: [])
        archive.attachments = Array(repeating: FolioArchive.Attachment(filename: "a", typeIdentifier: "t", data: Data()), count: Int(ArchiveLimits.maxAttachments) + 1)
        XCTAssertThrowsError(try archive.encoded()) { XCTAssertEqual($0 as? FolioFormatError, .tooLarge) }
        // A refused save leaves the previous file alone.
        let url = dir.appendingPathComponent("n.folio")
        try note("Original").write(to: url)
        var big = note()
        big.attachments = archive.attachments
        XCTAssertThrowsError(try big.write(to: url))
        XCTAssertEqual(try NoteFile.read(from: url).body.blocks[0].code, "Original")
        // Round trip within limits.
        let ok = try note("ok", attachment: "a.bin").encoded()
        XCTAssertEqual(try NoteFile.decode(ok).body.blocks[0].code, "ok")
    }

    // #273
    func testForgedLengthsGiveFormatErrors() throws {
        let data = try note().encoded()
        let header = 8
        for value in [UInt64.max, UInt64(Int.max), UInt64(Int.max) - 3] {
            var forged = Data(data.prefix(data.count - 4))
            withUnsafeBytes(of: value.littleEndian) { forged.replaceSubrange(header + 8..<header + 16, with: $0) }
            XCTAssertThrowsError(try FolioArchive.decode(resealed(forged))) { XCTAssertNotNil($0 as? FolioFormatError) }
            XCTAssertThrowsError(try FolioArchive.decode(resealed(forged), metaOnly: true))
        }
        // Random damage never crashes.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            var fuzzed = Data(data.prefix(data.count - 4))
            let i = Int.random(in: 4..<fuzzed.count, using: &generator)
            fuzzed[i] = UInt8.random(in: 0...255, using: &generator)
            _ = try? FolioArchive.decode(resealed(fuzzed))
        }
    }

    // #275
    func testMetaOnlyScanIsMarkedUnchecked() throws {
        var data = try note("Inhalt", attachment: "a.bin").encoded()
        data[data.count - 10] ^= 0xFF
        let head = try FolioArchive.decode(data, metaOnly: true)
        XCTAssertEqual(head.integrity, .headerOnly)
        XCTAssertThrowsError(try FolioArchive.decode(data)) { XCTAssertEqual($0 as? FolioFormatError, .checksumMismatch) }
        XCTAssertEqual(try FolioArchive.decode(try note().encoded()).integrity, .verified)
    }

    // #276
    func testUnknownFlagsAreRejected() throws {
        var data = Data(try note().encoded().dropLast(4))
        data[6] = 0x03  // LZFSE + an unknown bit
        XCTAssertThrowsError(try FolioArchive.decode(resealed(data))) { XCTAssertEqual($0 as? FolioFormatError, .unsupportedFlags(3)) }
        let report = FolioDiagnostics.diagnose(resealed(data))
        XCTAssertTrue(report.problems.contains { $0.severity == .error })
    }

    // #277
    func testExtraOrMissingBytesBeforeChecksum() throws {
        let payload = Data(try note().encoded().dropLast(4))
        XCTAssertThrowsError(try FolioArchive.decode(resealed(payload + Data([0, 1, 2])))) { XCTAssertEqual($0 as? FolioFormatError, .trailingBytes) }
        XCTAssertThrowsError(try FolioArchive.decode(resealed(payload.dropLast(2)))) { XCTAssertNotNil($0 as? FolioFormatError) }
        XCTAssertNoThrow(try FolioArchive.decode(resealed(payload)))
    }

    // #278
    func testUnreadableOptionalMetadataIsKeptAndReported() throws {
        let json = #"{"id":"6E1C2A86-4C1B-4C59-9D6E-6A1B9E5A0001","title":"T","environment":"kaputt","wikiLinks":["A"]}"#
        let meta = try JSONDecoder().decode(NoteMetadata.self, from: Data(json.utf8))
        XCTAssertNil(meta.environment)
        XCTAssertEqual(meta.wikiLinks, ["A"])
        XCTAssertEqual(meta.unreadable, ["environment": .string("kaputt")])
        let again = try JSONSerialization.jsonObject(with: JSONEncoder().encode(meta)) as? [String: Any]
        XCTAssertEqual(again?["environment"] as? String, "kaputt", "unlesbares Feld bleibt beim Speichern erhalten")
        // Missing legacy fields are fine and not reported.
        let legacy = try JSONDecoder().decode(NoteMetadata.self, from: Data(#"{"id":"6E1C2A86-4C1B-4C59-9D6E-6A1B9E5A0001"}"#.utf8))
        XCTAssertTrue(legacy.unreadable.isEmpty)
        // The diagnosis names it.
        var file = note()
        file.meta = meta
        let report = FolioDiagnostics.diagnose(try file.encoded())
        XCTAssertTrue(report.problems.contains { $0.message.contains("environment") })
    }

    // #279
    func testVersionsWithTheSameMillisecondAreAllKept() throws {
        let history = NoteHistory(library: dir)
        let id = UUID(), date = Date()
        XCTAssertNotNil(try history.record(try note("eins").encoded(), noteID: id, date: date, force: true))
        XCTAssertNotNil(try history.record(try note("zwei").encoded(), noteID: id, date: date, force: true))
        let versions = history.versions(of: id)
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(Set(try versions.map { try history.read($0).body.blocks[0].code ?? "" }), ["eins", "zwei"])
    }

    // #274
    func testEnvironmentOrAttachmentNameChangeIsANewVersion() throws {
        let base = note("x", attachment: "a.bin")
        var renamed = base
        renamed.attachments[0].header.filename = "b.bin"
        XCTAssertFalse(NoteHistory.sameContent(try base.encoded(), try renamed.encoded()))
        var env = base
        env.meta.environment = RunEnvironment()
        XCTAssertFalse(NoteHistory.sameContent(try base.encoded(), try env.encoded()))
        var touched = base
        touched.meta.modified = Date().addingTimeInterval(60)
        XCTAssertTrue(NoteHistory.sameContent(try base.encoded(), try touched.encoded()), "nur ein neues Datum ist keine Version")
    }

    // #271
    func testFileStampSeesSameDateChange() throws {
        let url = dir.appendingPathComponent("s.folio")
        try note("eins").write(to: url)
        let date = try XCTUnwrap(FileStamp.of(url)?.date)
        let before = FileStamp.of(url)
        try note("zwei, länger").write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        XCTAssertEqual(FileStamp.of(url)?.date?.timeIntervalSince(date) ?? 9, 0, accuracy: 1, "gleiche Sekunde")
        XCTAssertNotEqual(FileStamp.of(url), before)
    }

    #if os(macOS)
        // #324
        func testBackupCheckFindsMissingNotes() throws {
            let library = dir.appendingPathComponent("Bibliothek")
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            try note("a").write(to: library.appendingPathComponent("A.folio"))
            try note("b").write(to: library.appendingPathComponent("B.folio"))
            let manifest = dir.appendingPathComponent("m.json")
            try JSONSerialization.data(withJSONObject: ["notes": 2, "files": ["A.folio", "B.folio"]]).write(to: manifest)
            XCTAssertEqual(LibraryBackup.missing(manifest: manifest, found: ["A.folio"]), ["B.folio"])
            XCTAssertEqual(LibraryBackup.missing(manifest: manifest, found: ["A.folio", "B.folio"]), [])
            try JSONSerialization.data(withJSONObject: ["notes": 2]).write(to: manifest)
            XCTAssertEqual(LibraryBackup.missing(manifest: manifest, found: ["A.folio"]).count, 1, "ältere Sicherung: Anzahl zählt")
            XCTAssertEqual(LibraryBackup.missing(manifest: dir.appendingPathComponent("fehlt.json"), found: []), [LibraryBackup.manifestName])
            let backup = try LibraryBackup.create(library: library, in: dir.appendingPathComponent("Backups"))
            let check = try LibraryBackup.verify(backup.url)
            XCTAssertTrue(check.isValid, check.problems)
            XCTAssertEqual(check.notes, 2)
        }

        // #325
        func testFailedRestoreLeavesNothingBehind() throws {
            let broken = dir.appendingPathComponent("kaputt.zip")
            try Data("kein zip".utf8).write(to: broken)
            let parent = dir.appendingPathComponent("Ziel")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            XCTAssertThrowsError(try LibraryBackup.restore(broken, into: parent, name: "Wiederhergestellt"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [], "kein halbfertiger Ordner")
        }
    #endif
}

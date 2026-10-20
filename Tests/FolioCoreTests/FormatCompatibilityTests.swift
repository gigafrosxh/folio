import XCTest
@testable import FolioCore

/// JSON with sorted keys, so dictionaries compare independent of their order.
func sorted<T: Encodable>(_ value: T) throws -> Data {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return try e.encode(value)
}

/// #58: every block kind, Unicode, big attachments and damaged archives survive or fail cleanly.
final class FormatRoundtripTests: XCTestCase {
    private func everyBlock() -> NoteFile {
        let big = Data((0..<(12 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let a1 = FolioArchive.Attachment(filename: "groß 📷.png", typeIdentifier: "public.png", data: big)
        let a2 = FolioArchive.Attachment(filename: "Tabelle.numbers", typeIdentifier: "com.apple.iwork.numbers.sffnumbers", isPackage: true, data: Data("paket".utf8))
        var blocks: [BlockRecord] = []
        for kind in BlockKind.allCases {
            var b = BlockRecord(kind: kind)
            b.rtf = kind == .text ? Data("{\\rtf1 Größe 😀 עברית مرحبا e\u{301}}".utf8) : nil
            b.code = "print(\"∑ 𝔘𝔫𝔦𝔠𝔬𝔡𝔢 \\u{0}\") // \(kind)"
            b.language = "python"
            b.output = "Zeile 1\nZeile 2 ✓"
            b.outputIsError = true
            b.url = "https://例え.jp/パス?q=ä"
            b.attachmentID = kind == .file ? a2.id : a1.id
            b.height = 333.5
            b.width = 0.5
            b.mode = "isolated"
            b.caption = "Bild\u{200B}unterschrift"
            b.syncedAt = Date(timeIntervalSince1970: 1_700_000_000.25)
            b.connection = DatabaseConnection(name: "DB", driver: .postgresql, host: "localhost", port: 5432, database: "folio", user: "ü")
            b.stdin = "eingabe\n"
            b.interactive = true
            b.outputCollapsed = true
            blocks.append(b)
        }
        var meta = NoteMetadata(title: "Alle Blöcke 🧪", preview: "…", tags: ["ä/ö", "emoji😀"], created: Date(timeIntervalSince1970: 1),
                                modified: Date(timeIntervalSince1970: 2.5), pinned: true, searchText: String(repeating: "Ünïcödé ", count: 10_000))
        meta.links = [UUID(), UUID()]
        meta.kinds = BlockKind.allCases.map(\.rawValue)
        meta.environment = RunEnvironment(interpreters: ["python": "python3.12 {file}"], workingDirectory: "~/x", variables: ["A": "ü"], timeout: 12)
        return NoteFile(meta: meta, body: NoteBody(blocks: blocks), attachments: [a1, a2])
    }

    func testEveryBlockKindRoundTrips() throws {
        let file = everyBlock()
        let back = try NoteFile.decode(file.encoded())
        XCTAssertEqual(back.meta, file.meta)
        XCTAssertEqual(try sorted(back.body), try sorted(file.body))
        XCTAssertEqual(back.attachments.map(\.header.filename), file.attachments.map(\.header.filename))
        XCTAssertEqual(back.attachments.map(\.data), file.attachments.map(\.data))
        XCTAssertEqual(back.attachments.map(\.header.isPackage), [false, true])
        XCTAssertEqual(back.body.blocks.map(\.kind), BlockKind.allCases)
        // Metadata alone (the note list) reads without the body.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString).folio")
        defer { try? FileManager.default.removeItem(at: url) }
        try file.write(to: url)
        XCTAssertEqual(try NoteFile.readMetadata(at: url), file.meta)
        // Writing twice gives the same content (no hidden drift).
        XCTAssertEqual(try sorted(NoteFile.decode(back.encoded()).body), try sorted(back.body))
    }

    func testEmptyNote() throws {
        let empty = NoteFile(meta: NoteMetadata(), body: NoteBody())
        let back = try NoteFile.decode(empty.encoded())
        XCTAssertEqual(back.meta, empty.meta)
        XCTAssertTrue(back.body.blocks.isEmpty)
    }

    /// Cutting or changing any byte must give an error or a diagnosis, never a crash or a silent wrong note.
    func testDamagedArchivesFailCleanly() throws {
        var small = NoteFile(meta: NoteMetadata(title: "Klein"), body: NoteBody(blocks: [BlockRecord(kind: .code)]))
        small.body.blocks[0].code = String(repeating: "abc ", count: 300)
        small.attachments = [FolioArchive.Attachment(filename: "a.bin", typeIdentifier: "public.data", data: Data(repeating: 1, count: 2000))]
        let data = try small.encoded()
        for cut in stride(from: 0, to: data.count, by: max(data.count / 60, 1)) {
            XCTAssertThrowsError(try NoteFile.decode(data.prefix(cut)), "cut at \(cut)")
            _ = FolioDiagnostics.diagnose(data.prefix(cut))
        }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var broken = data
            let i = Int.random(in: 0..<broken.count, using: &rng)
            broken[i] ^= UInt8.random(in: 1...255, using: &rng)
            // The checksum catches every single-byte change.
            XCTAssertThrowsError(try NoteFile.decode(broken), "byte \(i)")
            let report = FolioDiagnostics.diagnose(broken)
            XCTAssertFalse(report.isHealthy)
        }
    }
}

/// #69: notes written by older Folio versions open in this one, and nothing is lost when saved again.
final class MigrationTests: XCTestCase {
    static let versions = ["0.1.0", "0.5.0", "0.9.0", "0.12.4", "0.14.0", "0.17.0"]

    private func fixture(_ version: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "note-\(version)", withExtension: "folio", subdirectory: "Fixtures"),
                                "fixture for \(version) missing")
        return try Data(contentsOf: url)
    }

    func testOldNotesOpen() throws {
        for v in Self.versions {
            let file = try NoteFile.decode(try fixture(v))
            XCTAssertEqual(file.meta.title, "Migration \(v)", v)
            XCTAssertEqual(file.meta.tags, ["alt"], v)
            XCTAssertTrue(file.meta.pinned, v)
            XCTAssertEqual(file.body.blocks.first?.kind, .text, v)
            XCTAssertEqual(file.body.blocks[1].code, "print('hallo ✓')", v)
            XCTAssertEqual(file.body.blocks[2].url, "https://example.com", v)
            XCTAssertEqual(file.body.blocks[3].attachmentID, file.attachments.first?.id, v)
            XCTAssertEqual(file.attachments.first?.data.count, 4096, v)
            XCTAssertTrue(FolioDiagnostics.diagnose(try fixture(v)).isHealthy, v)
        }
    }

    func testFieldsAddedLaterStartEmpty() throws {
        let old = try NoteFile.decode(try fixture("0.1.0"))
        XCTAssertEqual(old.meta.links, [])
        XCTAssertNil(old.meta.kinds, "0.1 did not store kinds")
        XCTAssertNil(old.meta.environment)
        XCTAssertNil(old.body.blocks[1].stdin)
        XCTAssertNil(old.body.blocks[1].outputCollapsed)
        let newer = try NoteFile.decode(try fixture("0.17.0"))
        XCTAssertEqual(newer.meta.environment?.variables, ["X": "1"])
        XCTAssertEqual(newer.body.blocks[1].stdin, "x")
        XCTAssertEqual(Set(newer.body.blocks.map(\.kind)), [.text, .code, .web, .image, .database, .math, .diagram, .audio])
    }

    func testOldNotesSurviveSavingAgain() throws {
        for v in Self.versions {
            let file = try NoteFile.decode(try fixture(v))
            let again = try NoteFile.decode(file.encoded())
            XCTAssertEqual(again.meta, file.meta, v)
            XCTAssertEqual(try sorted(again.body), try sorted(file.body), v)
        }
    }

    /// A note from a newer Folio with fields this version does not know still opens (the fields are ignored).
    func testUnknownFutureFieldsAreIgnored() throws {
        let meta = #"{"id":"\#(UUID().uuidString)","title":"Zukunft","created":1,"modified":2,"neuesFeld":{"x":1}}"#
        let body = #"{"blocks":[{"id":"\#(UUID().uuidString)","kind":"text","zukunft":true}],"version":9}"#
        let archive = FolioArchive(meta: Data(meta.utf8), body: Data(body.utf8))
        let file = try NoteFile.decode(archive.encoded())
        XCTAssertEqual(file.meta.title, "Zukunft")
        XCTAssertEqual(file.body.blocks.count, 1)
    }
}

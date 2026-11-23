import XCTest

@testable import FolioCore

/// Milestone 1.11.4: scanner cache (#301, #305), deep folders (#308), archive slices (#306), history copies (#304).
final class PerformanceSafetyTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func note(_ title: String, text: String = "x") -> NoteFile {
        var b = BlockRecord(kind: .code)
        b.code = text
        var meta = NoteMetadata(title: title)
        meta.searchText = text
        return NoteFile(meta: meta, body: NoteBody(blocks: [b]))
    }

    // #301
    func testCacheKeepsOneEntryPerPathAndForgetsDeletedNotes() throws {
        let scanner = LibraryScanner()
        let url = dir.appendingPathComponent("A.folio")
        for i in 0..<5 {
            try note("Fassung \(i)", text: String(repeating: "y", count: i + 1)).write(to: url)
            _ = scanner.scan(dir)
        }
        try note("B").write(to: dir.appendingPathComponent("B.folio"))
        _ = scanner.scan(dir)
        XCTAssertEqual(scanner.cachedCount, 2, "eine Fassung pro Pfad")
        try FileManager.default.removeItem(at: url)
        _ = scanner.scan(dir)
        XCTAssertEqual(scanner.cachedCount, 1, "gelöschte Notiz verlässt den Cache")
    }

    // #305
    func testSameSizeSameDateChangeIsNoticed() throws {
        let scanner = LibraryScanner()
        let url = dir.appendingPathComponent("A.folio")
        try note("Alpha").write(to: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let date = try XCTUnwrap(attrs[.modificationDate] as? Date)
        XCTAssertEqual(scanner.scan(dir).notes.first?.meta.title, "Alpha")
        try note("Omega").write(to: url)  // same length
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let result = scanner.scan(dir)
        XCTAssertEqual(result.notes.first?.meta.title, "Omega")
        XCTAssertEqual(result.cacheHits, 0)
    }

    // #371
    func testHeaderDamageWithRestoredDateIsNoticed() throws {
        let scanner = LibraryScanner()
        let url = dir.appendingPathComponent("A.folio")
        try note("Alpha").write(to: url)
        let date = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        XCTAssertEqual(scanner.scan(dir).notes.count, 1)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data("XXXX".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let result = scanner.scan(dir)
        XCTAssertEqual(result.unreadable.count, 1, "beschädigter Kopf wird erkannt")
        XCTAssertEqual(result.cacheHits, 0)
    }

    // #308
    func testVeryDeepFoldersDoNotOverflow() throws {
        var deep = dir!
        for i in 0..<(80) { deep.appendPathComponent("e\(i)") }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try note("Tief").write(to: deep.appendingPathComponent("T.folio"))
        try note("Oben").write(to: dir.appendingPathComponent("O.folio"))
        let result = LibraryScanner().scan(dir)
        XCTAssertTrue(result.notes.contains { $0.meta.title == "Oben" })
        XCTAssertTrue(result.skippedLinks.contains { $0.reason.contains("zu tief") })
    }

    // #306
    func testSlicedReadingStillRoundTrips() throws {
        let file = NoteFile(
            meta: NoteMetadata(title: "S"), body: NoteBody(),
            attachments: [.init(filename: "a", typeIdentifier: "t", data: Data(repeating: 7, count: 300_000))])
        let data = try file.encoded()
        let back = try NoteFile.decode(data)
        XCTAssertEqual(back.attachments.first?.data, Data(repeating: 7, count: 300_000))
        XCTAssertEqual(back.attachments.first?.data.startIndex, 0)
        // A slice of a bigger buffer decodes the same.
        let padded = Data([1, 2, 3]) + data
        XCTAssertEqual(try NoteFile.decode(padded.dropFirst(3)).meta.title, "S")
    }

    // #304
    func testHistoryCopiesFilesAndSkipsUnchanged() throws {
        let history = NoteHistory(library: dir)
        let url = dir.appendingPathComponent("N.folio")
        let id = UUID()
        try note("eins").write(to: url)
        XCTAssertNotNil(try history.recordFile(at: url, noteID: id))
        XCTAssertNil(try history.recordFile(at: url, noteID: id, date: Date().addingTimeInterval(1)), "gleiche Datei: keine neue Version")
        try note("zwei").write(to: url)
        let v = try XCTUnwrap(try history.recordFile(at: url, noteID: id, date: Date().addingTimeInterval(2)))
        XCTAssertEqual(try history.read(v).meta.title, "zwei")
        XCTAssertEqual(history.versions(of: id).count, 2)
    }
}

import XCTest
@testable import FolioCore

final class LibraryScannerTests: XCTestCase {
    private var base: URL!
    private var library: URL { base.appendingPathComponent("Bibliothek") }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("folio-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: library.appendingPathComponent("Notizen/Unter"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    @discardableResult
    private func note(_ path: String, title: String, text: String = "") throws -> URL {
        let url = library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try NoteFile(meta: NoteMetadata(title: title, searchText: text), body: NoteBody()).write(to: url)
        return url
    }

    private func link(_ path: String, to target: URL) throws {
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent(path), withDestinationURL: target)
    }

    func testScansFoldersNotesAndUnreadableFiles() throws {
        try note("Notizen/A.folio", title: "A")
        try note("Notizen/Unter/B.folio", title: "B")
        try Data("kaputt".utf8).write(to: library.appendingPathComponent("Notizen/C.folio"))
        let r = LibraryScanner().scan(library)
        XCTAssertEqual(Set(r.notes.map(\.meta.title)), ["A", "B"])
        XCTAssertEqual(r.unreadable.map(\.lastPathComponent), ["C.folio"])
        XCTAssertEqual(r.folders.map(\.name), ["Notizen"])
        XCTAssertEqual(r.folders.first?.children.map(\.name), ["Unter"])
    }

    func testSymlinkLoopsAreNotFollowed() throws {
        try note("Notizen/A.folio", title: "A")
        try link("Notizen/Unter/Schleife", to: library.appendingPathComponent("Notizen"))
        try link("Zurück", to: library)
        let r = LibraryScanner().scan(library)
        XCTAssertEqual(r.notes.count, 1, "the note is found once, the loop does not recurse")
        XCTAssertEqual(Set(r.skippedLinks.map(\.url.lastPathComponent)), ["Schleife", "Zurück"])
    }

    func testLinksOutsideTheLibraryAreSkipped() throws {
        let outside = base.appendingPathComponent("Fremd")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try NoteFile(meta: NoteMetadata(title: "Geheim"), body: NoteBody()).write(to: outside.appendingPathComponent("X.folio"))
        try link("Notizen/Fremder Ordner", to: outside)
        try link("Notizen/Fremde Notiz.folio", to: outside.appendingPathComponent("X.folio"))
        try link("Notizen/Tot", to: base.appendingPathComponent("gibt-es-nicht"))
        let r = LibraryScanner().scan(library)
        XCTAssertFalse(r.notes.contains { $0.meta.title == "Geheim" })
        XCTAssertEqual(r.skippedLinks.count, 3)
        XCTAssertTrue(r.skippedLinks.contains { $0.reason.contains("heraus") })
        XCTAssertTrue(r.skippedLinks.contains { $0.reason.contains("fehlt") })
    }

    func testLinksInsideTheLibraryWork() throws {
        try note("Archiv/Alt.folio", title: "Alt")
        try link("Notizen/Archiv-Link", to: library.appendingPathComponent("Archiv"))
        let r = LibraryScanner().scan(library)
        XCTAssertEqual(r.notes.filter { $0.meta.title == "Alt" }.count, 1, "listed once although reachable twice")
    }

    func testCacheReadsOnlyChangedFiles() throws {
        for i in 0..<20 { try note("Notizen/N\(i).folio", title: "N\(i)") }
        let scanner = LibraryScanner()
        XCTAssertEqual(scanner.scan(library).cacheHits, 0)
        XCTAssertEqual(scanner.scan(library).cacheHits, 20)
        Thread.sleep(forTimeInterval: 1.1)   // modification dates have 1 s resolution on some volumes
        try note("Notizen/N3.folio", title: "Neu")
        let r = scanner.scan(library)
        XCTAssertEqual(r.cacheHits, 19)
        XCTAssertTrue(r.notes.contains { $0.meta.title == "Neu" })
    }

    /// Benchmark for #62: 3,000 notes in 30 folders.
    func testLargeLibraryPerformance() throws {
        let words = ["Projekt", "Rezept", "Meeting", "Urlaub", "Budget", "Python", "Kunde", "Idee"]
        for i in 0..<3000 {
            let text = (0..<80).map { words[($0 * 7 + i) % words.count] }.joined(separator: " ")
            try note("Ordner \(i % 30)/Notiz \(i).folio", title: "Notiz \(i)", text: text)
        }
        let scanner = LibraryScanner()
        var start = Date()
        let first = scanner.scan(library)
        let cold = Date().timeIntervalSince(start)
        start = Date()
        _ = scanner.scan(library)
        let warm = Date().timeIntervalSince(start)
        XCTAssertEqual(first.notes.count, 3000)
        print("PERF scan cold \(cold) s, warm \(warm) s")
        XCTAssertLessThan(cold, 6)
        XCTAssertLessThan(warm, cold)

        let metas = first.notes.map(\.meta)
        let hay = metas.map(SearchFilter.haystack(for:))
        start = Date()
        let filter = SearchFilter(text: "budget kunde")
        for _ in 0..<20 { _ = zip(metas, hay).filter { filter.matches($0.0, folderPath: "", haystack: $0.1) } }
        let search = Date().timeIntervalSince(start) / 20
        print("PERF search \(search) s per keystroke")
        XCTAssertLessThan(search, 0.1)
    }
}

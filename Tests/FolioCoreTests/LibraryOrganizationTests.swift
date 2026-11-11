import XCTest
@testable import FolioCore

/// Manual order, favorites, smart views and note statistics (#13, #14, #15, #19).
final class LibraryOrganizationTests: XCTestCase {
    private func library() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("folio-org-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Order

    func testManualOrderKeepsUnknownItemsInPlace() {
        XCTAssertEqual(ManualOrder.apply(["a", "b", "c", "d"], order: ["c", "a", "x"], key: { $0 }, newFirst: true), ["b", "d", "c", "a"])
        XCTAssertEqual(ManualOrder.apply(["a", "b", "c", "d"], order: ["c", "a"], key: { $0 }, newFirst: false), ["c", "a", "b", "d"])
        XCTAssertEqual(ManualOrder.apply(["a", "b"], order: [String](), key: { $0 }, newFirst: true), ["a", "b"])
        XCTAssertEqual(ManualOrder.apply(["a", "b"], order: ["b", "b", "a"], key: { $0 }, newFirst: true), ["b", "a"], "duplicates in the order do not crash")
    }

    func testMoving() {
        XCTAssertEqual(ManualOrder.moving("c", before: "a", in: ["a", "b", "c"]), ["c", "a", "b"])
        XCTAssertEqual(ManualOrder.moving("a", before: "c", in: ["a", "b", "c"]), ["b", "a", "c"])
        XCTAssertEqual(ManualOrder.moving("a", before: nil, in: ["a", "b", "c"]), ["b", "c", "a"])
        XCTAssertEqual(ManualOrder.moving("a", before: "a", in: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(ManualOrder.moving("a", before: "fehlt", in: ["a", "b"]), ["b", "a"])
        XCTAssertEqual(ManualOrder.moving("neu", before: "b", in: ["a", "b"]), ["a", "neu", "b"])
    }

    func testStepping() {
        XCTAssertEqual(ManualOrder.stepping("b", by: -1, in: ["a", "b", "c"]), ["b", "a", "c"])
        XCTAssertEqual(ManualOrder.stepping("b", by: 1, in: ["a", "b", "c"]), ["a", "c", "b"])
        XCTAssertEqual(ManualOrder.stepping("a", by: -1, in: ["a", "b"]), ["a", "b"], "the first stays first")
        XCTAssertEqual(ManualOrder.stepping("b", by: 1, in: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(ManualOrder.stepping("x", by: 1, in: ["a", "b"]), ["a", "b"])
    }

    func testOnlyDateOrdersGroupByDate() {
        XCTAssertEqual(NoteSortMode.allCases.filter(\.groupsByDate), [.modified, .created])
    }

    // MARK: File

    func testRoundtripInTheLibrary() throws {
        let lib = try library()
        XCTAssertEqual(LibraryOrganization.load(from: lib), .missing)
        var org = LibraryOrganization()
        let a = UUID(), b = UUID()
        org.sortMode = .manual
        org.favorites = [b, a]
        org.noteOrder = ["all": [a, b], "folder:Projekte/Alt": [b]]
        org.folderOrder = ["": ["Zebra", "Apfel"]]
        var filter = SearchFilter(text: "rezept", tags: ["kochen"], folder: "Küche", period: .week, types: ["code"])
        filter.properties = ["status": "offen"]
        org.smartViews = [SmartView(name: "Rezepte", filter: filter)]
        try org.save(to: lib)
        XCTAssertEqual(LibraryOrganization.load(from: lib), .loaded(org))
        XCTAssertTrue(LibraryOrganization.file(in: lib).path.hasSuffix(".folio/organization.json"))
    }

    func testOlderOrPartialFilesStillLoad() throws {
        let lib = try library()
        let url = LibraryOrganization.file(in: lib)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"favorites":[],"sortMode":"spaeter-erfunden","smartViews":[{"id":"\#(UUID().uuidString)","name":"A","filter":{"period":"unbekannt"}}],"zukunft":1}"#.utf8).write(to: url)
        guard case .loaded(let org) = LibraryOrganization.load(from: lib) else { return XCTFail("not loaded") }
        XCTAssertEqual(org.sortMode, .modified)
        XCTAssertEqual(org.smartViews.first?.filter, SearchFilter())
    }

    func testBrokenFileIsSetAsideNotOverwritten() throws {
        let lib = try library()
        let url = LibraryOrganization.file(in: lib)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{kaputt".utf8).write(to: url)
        guard case .unreadable(let kept) = LibraryOrganization.load(from: lib) else { return XCTFail("should be unreadable") }
        let name = try XCTUnwrap(kept)
        XCTAssertEqual(try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(name)), Data("{kaputt".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(LibraryOrganization.load(from: lib), .missing)
    }

    // MARK: Favorites and views

    func testFavoritesToggleAndPrune() {
        var org = LibraryOrganization()
        let a = UUID(), b = UUID()
        org.toggleFavorite(a); org.toggleFavorite(b)
        XCTAssertEqual(org.favorites, [a, b])
        org.toggleFavorite(a)
        XCTAssertFalse(org.isFavorite(a))
        org.noteOrder = ["all": [a, b], "tag:x": [a]]
        org.prune(keeping: [b])
        XCTAssertEqual(org.favorites, [b])
        XCTAssertEqual(org.noteOrder, ["all": [b]])
    }

    func testSmartViewSummary() {
        var f = SearchFilter(text: "rezept", tags: ["kochen"], folder: "Küche", period: .week, types: ["code"])
        f.properties = ["status": "*"]
        XCTAssertEqual(SmartView(name: "x", filter: f).summary, "„rezept“ · #kochen · Ordner Küche · Code · Letzte 7 Tage · status: vorhanden")
        XCTAssertEqual(SmartView(name: "x", filter: SearchFilter()).summary, "Alle Notizen")
    }

    func testSavedFilterMatchesLikeTheSearch() throws {
        let f = SearchFilter.parse("rezept tag:kochen").merged(with: SearchFilter(types: ["code"]))
        let back = try JSONDecoder().decode(SearchFilter.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back, f)
        var meta = NoteMetadata(title: "Rezept Suppe", tags: ["kochen"])
        meta.kinds = ["text", "code"]
        XCTAssertTrue(back.matches(meta, folderPath: ""))
        meta.kinds = ["text"]
        XCTAssertFalse(back.matches(meta, folderPath: ""))
    }

    // MARK: Statistics

    func testStatistics() {
        let s = NoteStatistics(texts: ["Hallo  Welt!\n\n• E-Mail an 1.000 Leute\n☐ ", "Zwei"], code: ["a = 1\n\n  \nprint(a)", "   ", "x"])
        XCTAssertEqual(s.words, 7)
        XCTAssertEqual(s.paragraphs, 4)
        XCTAssertEqual(s.characters, "Hallo  Welt!\n\n• E-Mail an 1.000 Leute\n☐ ".count + 4)
        XCTAssertEqual(s.charactersWithoutSpaces, s.characters - 10)
        XCTAssertEqual(s.codeBlocks, 2)
        XCTAssertEqual(s.codeLines, 3)
        XCTAssertEqual(s.readingMinutes, 1)
    }

    func testEmptyNoteAndUnicode() {
        XCTAssertEqual(NoteStatistics(texts: [], code: []), NoteStatistics())
        XCTAssertEqual(NoteStatistics(texts: [""], code: [""]).readingMinutes, 0)
        let s = NoteStatistics(texts: ["Größe 😀 日本語 👨‍👩‍👧"], code: [])
        XCTAssertEqual(s.words, 2, "emoji are not words")
        XCTAssertEqual(s.charactersWithoutSpaces, 10)
        XCTAssertEqual(NoteStatistics(texts: [String(repeating: "wort ", count: 1_000)], code: []).readingMinutes, 5)
    }
}

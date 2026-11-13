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

    // MARK: Fixes of 1.4.1

    func testReorderingAPartKeepsTheRest() {
        // #170: a search shows B and D; D goes in front of B; E, A and C keep their places.
        XCTAssertEqual(ManualOrder.merging(["D", "B"], into: ["E", "A", "B", "C", "D"]), ["E", "A", "D", "C", "B"])
        XCTAssertEqual(ManualOrder.merging(["x", "D", "B", "D"], into: ["E", "A", "B", "C", "D"]), ["E", "A", "D", "C", "B"], "strangers and doubles are ignored")
        XCTAssertEqual(ManualOrder.merging([String](), into: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(ManualOrder.merging(["c", "b", "a"], into: ["a", "b", "c"]), ["c", "b", "a"])
    }

    func testDoublesAreDroppedOnLoad() throws {
        // #171
        let a = UUID(), b = UUID(), v = UUID()
        let json = """
        {"favorites":["\(a)","\(b)","\(a)"],"noteOrder":{"all":["\(b)","\(b)","\(a)"]},"folderOrder":{"":["X","Y","X"]},
         "smartViews":[{"id":"\(v)","name":"Eins","filter":{}},{"id":"\(v)","name":"Zwei","filter":{}}]}
        """
        var org = try JSONDecoder().decode(LibraryOrganization.self, from: Data(json.utf8))
        XCTAssertEqual(org.favorites, [a, b])
        XCTAssertEqual(org.noteOrder["all"], [b, a])
        XCTAssertEqual(org.folderOrder[""], ["X", "Y"])
        XCTAssertEqual(org.smartViews.map(\.name), ["Eins"])
        org.favorites = [a, a]
        org.toggleFavorite(a)
        XCTAssertFalse(org.isFavorite(a), "one click removes a favorite even when it is stored twice")
    }

    func testMergingKeepsWhatBothSidesAdded() {
        // #175
        let a = UUID(), b = UUID(), c = UUID()
        var mine = LibraryOrganization(), theirs = LibraryOrganization()
        mine.sortMode = .title
        mine.favorites = [a, b]
        mine.noteOrder = ["all": [a, b]]
        mine.smartViews = [SmartView(name: "Meine", filter: SearchFilter(text: "x"))]
        theirs.favorites = [c, a]
        theirs.noteOrder = ["all": [b, a], "tag:x": [c]]
        theirs.folderOrder = ["": ["Z", "A"]]
        theirs.smartViews = [mine.smartViews[0], SmartView(name: "Ihre", filter: SearchFilter(text: "y"))]
        let merged = mine.merging(theirs)
        XCTAssertEqual(merged.sortMode, .title)
        XCTAssertEqual(merged.favorites, [a, b, c])
        XCTAssertEqual(merged.noteOrder, ["all": [a, b], "tag:x": [c]])
        XCTAssertEqual(merged.folderOrder, ["": ["Z", "A"]])
        XCTAssertEqual(merged.smartViews.map(\.name), ["Meine", "Ihre"])
        XCTAssertEqual(mine.merging(LibraryOrganization()), mine)
    }

    func testThreeWayMergeKeepsRemovalsOfBothSides() {
        // #180
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var base = LibraryOrganization()
        base.favorites = [a, b, c]
        let keep = SmartView(name: "Bleibt", filter: SearchFilter(text: "k")), gone = SmartView(name: "Weg", filter: SearchFilter(text: "w"))
        base.smartViews = [keep, gone]
        base.noteOrder = ["all": [a, b], "tag:x": [c]]
        var mine = base, theirs = base
        mine.favorites.removeAll { $0 == a }               // removed here
        mine.smartViews.removeAll { $0.id == gone.id }      // deleted here
        mine.noteOrder["all"] = [b, a]                      // reordered here
        theirs.favorites.removeAll { $0 == c }              // removed there
        theirs.favorites.append(d)                          // added there
        let added = SmartView(name: "Neu dort", filter: SearchFilter(text: "n"))
        theirs.smartViews.append(added)
        theirs.smartViews[0].name = "Umbenannt dort"
        theirs.noteOrder["tag:x"] = nil                     // dropped there
        theirs.sortMode = .title
        let merged = mine.merging(theirs, base: base)
        XCTAssertEqual(merged.favorites, [b, d])
        XCTAssertEqual(merged.smartViews.map(\.name), ["Umbenannt dort", "Neu dort"])
        XCTAssertEqual(merged.noteOrder, ["all": [b, a]])
        XCTAssertEqual(merged.sortMode, .title, "unchanged here, so the other side's choice wins")
        var both = mine
        both.sortMode = .created
        XCTAssertEqual(both.merging(theirs, base: base).sortMode, .created, "changed on both sides: this side wins")
        XCTAssertEqual(base.merging(base, base: base), base)
        XCTAssertEqual(mine.merging(base, base: base), mine, "nothing changed there: this side stays as it is")
    }

    func testRenamedTagKeepsItsOrderAndViews() {
        // #174
        let a = UUID(), b = UUID(), c = UUID()
        var org = LibraryOrganization()
        org.noteOrder = ["tag:alt": [a, b], "tag:alt/unter": [c], "tag:altbau": [c], "all": [a]]
        org.smartViews = [SmartView(name: "V", filter: SearchFilter(tags: ["alt", "anders"]))]
        org.renameTag("alt", to: "neu")
        XCTAssertEqual(org.noteOrder, ["tag:neu": [a, b], "tag:neu/unter": [c], "tag:altbau": [c], "all": [a]])
        XCTAssertEqual(org.smartViews[0].filter.tags, ["neu", "anders"])

        org.noteOrder["tag:ziel"] = [c, a]
        org.renameTag("neu", to: "ziel")
        XCTAssertEqual(org.noteOrder["tag:ziel"], [c, a, b], "merging keeps the target's order and adds the rest")
        XCTAssertEqual(org.noteOrder["tag:ziel/unter"], [c])

        org.renameTag("ziel", to: nil)
        XCTAssertNil(org.noteOrder["tag:ziel"])
        XCTAssertNil(org.noteOrder["tag:ziel/unter"])
        XCTAssertEqual(org.smartViews[0].filter.tags, ["anders"])
        XCTAssertEqual(org.noteOrder["all"], [a])
    }

    func testListNumbersAreNotWords() {
        // #179
        XCTAssertEqual(NoteStatistics.wordCount("Testnotiz\nInhalt\n1. eins\n2. zwei"), 4)
        XCTAssertEqual(NoteStatistics.wordCount("\t12) zwölf Dinge\n3."), 3, "a line with only a number keeps it")
        XCTAssertEqual(NoteStatistics.wordCount("Im Jahr 2024. war es 1.000 mal"), 7, "numbers inside a sentence count")
        XCTAssertEqual(NoteStatistics.wordCount("2024. war ein Jahr"), 4, "a year at the start of a line is no list number")
        XCTAssertEqual(NoteStatistics.wordCount("1. "), 0)
    }

    func testBackupContainsTheOrganization() throws {
        // #176
        let lib = try library()
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("Notizen"), withIntermediateDirectories: true)
        try NoteFile(meta: NoteMetadata(title: "A"), body: NoteBody()).write(to: lib.appendingPathComponent("Notizen/A.folio"))
        var org = LibraryOrganization()
        org.favorites = [UUID()]
        org.smartViews = [SmartView(name: "Gesichert", filter: SearchFilter(text: "x"))]
        try org.save(to: lib)
        try Data("verlauf".utf8).write(to: lib.appendingPathComponent(".folio/sonstiges.txt"))
        let backups = try library()
        let backup = try LibraryBackup.create(library: lib, in: backups)
        XCTAssertEqual(try LibraryBackup.verify(backup.url).damaged, [])
        let restored = try LibraryBackup.restore(backup.url, into: backups, name: "Zurück")
        XCTAssertEqual(LibraryOrganization.load(from: restored), .loaded(org))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.appendingPathComponent(".folio/sonstiges.txt").path), "the rest of .folio stays out")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.appendingPathComponent("Notizen/A.folio").path))
    }

    func testFileWithoutReadPermissionIsSetAsideNotTreatedAsMissing() throws {
        // #188
        let lib = try library()
        var org = LibraryOrganization()
        org.favorites = [UUID()]
        try org.save(to: lib)
        let url = LibraryOrganization.file(in: lib)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        guard case .unreadable(let kept) = LibraryOrganization.load(from: lib) else { return XCTFail("not set aside") }
        let name = try XCTUnwrap(kept)
        let moved = url.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: moved.path)
        XCTAssertEqual(try JSONDecoder().decode(LibraryOrganization.self, from: Data(contentsOf: moved)), org, "nothing of it was lost")
        XCTAssertEqual(LibraryOrganization.load(from: lib), .missing)
    }

    func testDoubledAttachmentIdsDoNotCrash() throws {
        // #187
        let id = UUID()
        var block = BlockRecord(kind: .image)
        block.attachmentID = id
        let atts = [FolioArchive.Attachment(id: id, filename: "a.txt", typeIdentifier: "public.plain-text", data: Data("A".utf8)),
                    FolioArchive.Attachment(id: id, filename: "b.txt", typeIdentifier: "public.plain-text", data: Data("B".utf8))]
        let data = try NoteFile(meta: NoteMetadata(title: "Doppelt"), body: NoteBody(blocks: [block]), attachments: atts).encoded()
        let file = try NoteFile.decode(data)
        XCTAssertEqual(Set(file.attachments.map(\.id)).count, 2, "every attachment has its own id now")
        XCTAssertEqual(file.attachments.first { $0.id == id }?.data, Data("A".utf8), "the block keeps the first one")
        XCTAssertEqual(Set(file.attachments.map(\.data)), [Data("A".utf8), Data("B".utf8)], "no data is dropped")
        // #194: the second one is kept in a block of its own, so saving does not drop it.
        let extra = try XCTUnwrap(file.attachments.first { $0.id != id })
        XCTAssertTrue(file.body.blocks.contains { $0.kind == .file && $0.attachmentID == extra.id })
        let again = try NoteFile.decode(file.encoded())
        XCTAssertEqual(Set(again.attachments.map(\.data)), [Data("A".utf8), Data("B".utf8)])
        XCTAssertEqual(again.body.blocks.count, file.body.blocks.count, "a healthy file gets no extra blocks")
        let report = FolioDiagnostics.diagnose(data)
        XCTAssertTrue(report.problems.contains { $0.message.contains("doppelte Kennung") }, "the diagnosis names the problem")
    }

    func testPropertyOnlyChangesAreNewVersions() throws {
        // #209
        let lib = try library()
        let history = NoteHistory(library: lib)
        var meta = NoteMetadata(title: "Aufgabe")
        meta.properties = [NoteProperty(name: "Status", kind: .status, value: "Offen", options: ["Offen", "Erledigt"])]
        let id = meta.id
        let first = try NoteFile(meta: meta, body: NoteBody()).encoded()
        XCTAssertNotNil(try history.record(first, noteID: id, force: true))
        meta.properties?[0].value = "Erledigt"
        let second = try NoteFile(meta: meta, body: NoteBody()).encoded()
        XCTAssertNotNil(try history.record(second, noteID: id, date: Date().addingTimeInterval(1), force: true), "a new status is a new version")
        XCTAssertEqual(history.versions(of: id).count, 2)
        meta.title = "Nur der Titel"
        let third = try NoteFile(meta: meta, body: NoteBody()).encoded()
        XCTAssertNil(try history.record(third, noteID: id, date: Date().addingTimeInterval(2), force: true), "other metadata alone still is no new version")
    }

    func testDailyNotesSurviveAMerge() {
        // #208
        var mine = LibraryOrganization(), theirs = LibraryOrganization()
        let a = UUID(), b = UUID()
        mine.dailyNotes = ["2027-01-15": a]
        theirs.dailyNotes = ["2027-01-15": b, "2027-01-16": b]
        let merged = mine.merging(theirs, base: LibraryOrganization())
        XCTAssertEqual(merged.dailyNotes, ["2027-01-15": a, "2027-01-16": b])
        XCTAssertEqual(mine.merging(theirs).dailyNotes, ["2027-01-15": a, "2027-01-16": b])
    }

    func testWholeWordsKnowLettersBeyondTheBasicPlane() {
        // #212: 𐐀 (U+10400) is a letter in two UTF-16 units.
        let text = "𐐀cat cat𐐀 cat"
        let hits = FindInText.ranges(of: "cat", in: text, options: .init(wholeWord: true))
        XCTAssertEqual(hits, [NSRange(location: 12, length: 3)])
        XCTAssertEqual(FindInText.ranges(of: "cat", in: "😀cat cat😀", options: .init(wholeWord: true)).count, 2, "emoji are no letters")
        XCTAssertEqual(FindInText.ranges(of: "cat", in: "cat", options: .init(wholeWord: true)).count, 1)
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

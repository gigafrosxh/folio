import XCTest
@testable import FolioCore

final class OrganizationTests: XCTestCase {
    func testNoteLinkRoundTrip() {
        let id = UUID()
        let url = NoteLink.url(for: id)
        XCTAssertEqual(url.absoluteString, "folio://note/\(id.uuidString)")
        XCTAssertEqual(NoteLink.id(from: url), id)
        XCTAssertNil(NoteLink.id(from: URL(string: "https://example.com/note/\(id.uuidString)")!))
        XCTAssertNil(NoteLink.id(from: URL(string: "folio://note/kaputt")!))

        var a = NoteMetadata(title: "A"), b = NoteMetadata(title: "B"), c = NoteMetadata(title: "C")
        a.links = [c.id]
        b.links = [c.id, a.id]
        c.links = [c.id]   // a link to itself is not a backlink
        XCTAssertEqual(NoteLink.backlinks(to: c.id, in: [a, b, c]).map(\.title), ["A", "B"])
        XCTAssertEqual(NoteLink.backlinks(to: a.id, in: [a, b, c]).map(\.title), ["B"])
    }

    func testMetadataDecodesOldNotesWithoutNewFields() throws {
        let old = #"{"id":"\#(UUID().uuidString)","title":"Alt","created":0,"modified":0}"#
        let meta = try JSONDecoder().decode(NoteMetadata.self, from: Data(old.utf8))
        XCTAssertEqual(meta.links, [])
        XCTAssertNil(meta.kinds)
    }

    func testFuzzyRanking() {
        let titles = ["Projektplan Q4", "Einkaufsliste", "Protokoll Teammeeting", "Python Notizen", "Plan"]
        XCTAssertEqual(FuzzyMatch.rank(titles, query: "plan", text: { $0 }).first, "Plan")
        XCTAssertEqual(FuzzyMatch.rank(titles, query: "ptm", text: { $0 }), ["Protokoll Teammeeting"])
        XCTAssertEqual(FuzzyMatch.rank(titles, query: "pq4", text: { $0 }), ["Projektplan Q4"])
        XCTAssertEqual(FuzzyMatch.rank(titles, query: "", text: { $0 }), titles)
        XCTAssertNil(FuzzyMatch.score("xyz", in: "Einkaufsliste"))
        // Word starts beat scattered letters.
        XCTAssertGreaterThan(FuzzyMatch.score("pn", in: "Python Notizen")!, FuzzyMatch.score("pn", in: "Projektplan Q4")!)
    }

    func testRecentList() {
        var r = RecentList(limit: 3)
        let ids = (0..<5).map { _ in UUID() }
        for id in ids { r.opened(id) }
        XCTAssertEqual(r.ids, [ids[4], ids[3], ids[2]])
        r.opened(ids[2])
        XCTAssertEqual(r.ids, [ids[2], ids[4], ids[3]])
        r.remove(ids[4])
        XCTAssertEqual(r.ids, [ids[2], ids[3]])
    }

    func testSearchParsing() {
        let f = SearchFilter.parse("tag:Rezept #urlaub ordner:Projekte/Alt typ:code seit:7 pasta  sauce")
        XCTAssertEqual(f.tags, ["rezept", "urlaub"])
        XCTAssertEqual(f.folder, "Projekte/Alt")
        XCTAssertEqual(f.types, ["code"])
        XCTAssertEqual(f.period, .week)
        XCTAssertEqual(f.text, "pasta sauce")
        XCTAssertEqual(SearchFilter.parse("C# lernen").text, "C# lernen", "C# is not a tag")
        XCTAssertFalse(SearchFilter.parse("einfach").hasFilters)
    }

    func testSearchMatching() {
        let now = Date()
        var m = NoteMetadata(title: "Pasta Rezept", tags: ["rezept", "projekt/alpha"], modified: now.addingTimeInterval(-3 * 86_400),
                             searchText: "Tomaten und Basilikum")
        m.kinds = ["text", "code", "image"]
        XCTAssertTrue(SearchFilter(text: "basilikum pasta").matches(m, folderPath: "Küche", now: now))
        XCTAssertFalse(SearchFilter(text: "basilikum oregano").matches(m, folderPath: "Küche", now: now))
        XCTAssertTrue(SearchFilter(tags: ["projekt"]).matches(m, folderPath: "", now: now), "parent tag finds nested tag")
        XCTAssertFalse(SearchFilter(tags: ["rezept", "urlaub"]).matches(m, folderPath: "", now: now))
        XCTAssertTrue(SearchFilter(folder: "Küche").matches(m, folderPath: "Küche/Italienisch", now: now), "subfolders count")
        XCTAssertFalse(SearchFilter(folder: "Küch").matches(m, folderPath: "Küche", now: now))
        XCTAssertTrue(SearchFilter(period: .week).matches(m, folderPath: "", now: now))
        XCTAssertFalse(SearchFilter(period: .today).matches(m, folderPath: "", now: now))
        XCTAssertTrue(SearchFilter(types: ["bild", "code"]).matches(m, folderPath: "", now: now))
        XCTAssertFalse(SearchFilter(types: ["audio"]).matches(m, folderPath: "", now: now))
        m.kinds = nil
        XCTAssertTrue(SearchFilter(types: ["audio"]).matches(m, folderPath: "", kinds: ["audio"], now: now), "kinds read from the body")
        let merged = SearchFilter.parse("tag:a text").merged(with: SearchFilter(tags: ["b"], period: .month))
        XCTAssertEqual(merged.tags, ["a", "b"])
        XCTAssertEqual(merged.period, .month)
        XCTAssertEqual(merged.text, "text")
    }

    func testTagRenameMergeRemove() {
        let text = "Heute #Projekt und #projekt/alpha, nicht #projektplan oder C#projekt. #andere"
        XCTAssertEqual(TagEdit.apply(text, tag: "projekt", to: "arbeit"),
                       "Heute #arbeit und #arbeit/alpha, nicht #projektplan oder C#projekt. #andere")
        XCTAssertEqual(TagEdit.apply("a #alt b #alt", tag: "alt", to: nil), "a b ")
        XCTAssertEqual(TagEdit.apply("x #a", tag: "b", to: "c"), "x #a")
        XCTAssertEqual(TagEdit.normalized("#Neue Idee"), "neue-idee")
        XCTAssertNil(TagEdit.normalized("#123"))
        XCTAssertNil(TagEdit.normalized("   "))
    }

    func testTemplatePlaceholders() {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 20; c.hour = 9; c.minute = 5
        let date = Calendar(identifier: .gregorian).date(from: c)!
        let out = TemplateText.fill("Meeting {{Datum}} um {{uhrzeit}} ({{wochentag}}, KW {{kw}}) {{unbekannt}}", now: date)
        XCTAssertEqual(out, "Meeting 20.10.2026 um 09:05 (Dienstag, KW 43) {{unbekannt}}")
    }

    func testMarkdownPieces() {
        let md = """
        # Titel

        Text mit **fett**.

        ```swift
        let x = 1
        ```

        ```mermaid
        graph TD; A-->B
        ```

        $$
        e^{i\\pi}+1=0
        $$

        ![Bild](bilder/a.png)
        Ende
        """
        XCTAssertEqual(MarkdownStructure.pieces(md), [
            .text("# Titel\n\nText mit **fett**."),
            .code(language: "swift", code: "let x = 1"),
            .mermaid("graph TD; A-->B"),
            .math("e^{i\\pi}+1=0"),
            .image(alt: "Bild", path: "bilder/a.png"),
            .text("Ende"),
        ])
        XCTAssertEqual(MarkdownStructure.pieces("$$a^2$$"), [.math("a^2")])
        XCTAssertEqual(MarkdownStructure.title(of: "\n## Hallo Welt\nText", fallback: "x"), "Hallo Welt")
        XCTAssertEqual(MarkdownStructure.title(of: "Kein Titel", fallback: "datei"), "datei")
        XCTAssertEqual(MarkdownStructure.safeFileName("a/b: c?"), "a-b- c-")
    }
}

final class FindInTextTests: XCTestCase {
    func testFindOptions() {
        let text = "Haus, haus und Häuser; Hausboot. HAUS"
        XCTAssertEqual(FindInText.ranges(of: "haus", in: text).count, 5, "Häuser counts: umlauts are ignored")
        XCTAssertEqual(FindInText.ranges(of: "haus", in: text, options: .init(caseSensitive: true)).map(\.location), [6])
        XCTAssertEqual(FindInText.ranges(of: "haus", in: text, options: .init(wholeWord: true)).count, 3)
        XCTAssertEqual(FindInText.ranges(of: "hauser", in: text).count, 1, "diacritics are ignored without case sensitivity")
        XCTAssertEqual(FindInText.ranges(of: "", in: text), [])
        XCTAssertEqual(FindInText.ranges(of: "aa", in: "aaaa").map(\.location), [0, 2], "matches do not overlap")
    }
}

import XCTest
@testable import FolioCore

/// Wiki links, the link index, mentions, layout and template variables (#110–#121).
final class LinkGraphTests: XCTestCase {
    private func meta(_ title: String, text: String = "", links: [UUID] = [], tags: [String] = [], modified: Date = Date()) -> NoteMetadata {
        var m = NoteMetadata(title: title, modified: modified, searchText: title + "\n" + text)
        m.links = links
        m.tags = tags
        return m
    }

    func testWikiLinkParsing() {
        let text = "Siehe [[Projekt Alpha]] und [[ beta |die Beta]], dazu ![[Protokoll]] aber nicht [[]] oder [[a\nb]]."
        let links = WikiLink.find(in: text)
        XCTAssertEqual(links.map(\.target), ["Projekt Alpha", "beta", "Protokoll"])
        XCTAssertEqual(links[1].alias, "die Beta")
        XCTAssertEqual(links.map(\.isEmbed), [false, false, true])
        XCTAssertEqual((text as NSString).substring(with: links[0].range), "[[Projekt Alpha]]")
        XCTAssertEqual(WikiLink.targets(in: "[[A]] [[a]] [[B]]"), ["A", "B"], "same title once, case-insensitive")
        let url = WikiLink.url(for: "Über uns / Team")
        XCTAssertEqual(WikiLink.target(from: url), "Über uns / Team", "round trip through the URL")
    }

    func testIndexResolvesLinksBacklinksAndUnresolved() {
        let a = meta("Alpha"), c = meta("Gamma")
        let b = meta("Beta", text: "verweist auf [[alpha]] und [[Fehlt]]", links: [c.id])
        var index = LinkIndex([(a, "N"), (b, "N"), (c, "N")])
        XCTAssertEqual(index.outgoing(b.id), [a.id, c.id])
        XCTAssertEqual(index.backlinks(a.id), [b.id])
        XCTAssertEqual(index.unresolved(b.id), [WikiLink.key("Fehlt")])
        XCTAssertEqual(index.orphans(), [])

        // A note called „Fehlt“ appears: the link resolves without touching Beta (#115).
        let f = meta("Fehlt")
        index.update(f, folder: "N")
        XCTAssertTrue(index.outgoing(b.id).contains(f.id))
        XCTAssertTrue(index.unresolved(b.id).isEmpty)

        // Renaming Alpha breaks the [[alpha]] link, deleting Gamma removes the id link (#119).
        var renamed = a
        renamed.title = "Alpha 2"
        index.update(renamed, folder: "N")
        XCTAssertFalse(index.outgoing(b.id).contains(a.id))
        index.remove(c.id)
        XCTAssertFalse(index.outgoing(b.id).contains(c.id))
        XCTAssertEqual(index.orphans(), [a.id])
    }

    func testCyclesNeighborhoodAndPath() {
        // A → B → C → A (a cycle) and D alone; self links are ignored.
        var a = meta("A"), b = meta("B"), c = meta("C")
        let d = meta("D", text: "[[D]]")
        a.searchText = "A [[B]] [[A]]"; b.searchText = "B [[C]]"; c.searchText = "C [[A]]"
        let index = LinkIndex([(a, ""), (b, ""), (c, ""), (d, "")])
        XCTAssertEqual(index.edges().count, 3)
        XCTAssertEqual(index.neighborhood(of: a.id, depth: 1), [a.id, b.id, c.id])
        XCTAssertEqual(index.neighborhood(of: a.id, depth: 5), [a.id, b.id, c.id], "cycle terminates")
        XCTAssertEqual(index.orphans(), [d.id])
        XCTAssertEqual(index.path(from: b.id, to: c.id), [b.id, c.id])
        XCTAssertNil(index.path(from: a.id, to: d.id))
    }

    func testDuplicateTitlesResolveToNewest() {
        let old = meta("Notiz", modified: Date(timeIntervalSince1970: 0))
        let new = meta("notiz", modified: Date(timeIntervalSince1970: 100))
        let index = LinkIndex([(old, ""), (new, "")])
        XCTAssertEqual(index.resolve("NOTIZ"), new.id)
    }

    func testUnlinkedMentions() {
        let target = meta("Projekt Alpha")
        let mentions = meta("Bericht", text: "Im projekt alpha gab es Neues.")
        let linked = meta("Plan", text: "Siehe [[Projekt Alpha]].")
        let partial = meta("Anderes", text: "Projekt Alphabet ist etwas anderes.")
        let notes = [target, mentions, linked, partial]
        let index = LinkIndex(notes.map { ($0, "") })
        XCTAssertEqual(Mentions.unlinked(to: target.id, title: target.title, in: notes, index: index), [mentions.id])
        XCTAssertEqual(Mentions.ranges(of: "Ab", in: "Ab und ab"), [], "too short titles are no mentions")
    }

    func testLayoutIsFiniteDeterministicAndSeparatesNodes() {
        let ids = (0..<40).map { _ in UUID() }
        let edges = (1..<40).map { (ids[0], ids[$0]) }
        let one = GraphLayout.compute(nodes: ids, edges: edges)
        let two = GraphLayout.compute(nodes: ids, edges: edges)
        XCTAssertEqual(one, two)
        XCTAssertTrue(one.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let points = ids.compactMap { one[$0] }
        var minDistance = Double.infinity
        for i in 0..<points.count { for j in (i + 1)..<points.count { minDistance = min(minDistance, hypot(points[i].x - points[j].x, points[i].y - points[j].y)) } }
        XCTAssertGreaterThan(minDistance, 5, "nodes do not sit on top of each other")
        XCTAssertTrue(GraphLayout.compute(nodes: [], edges: []).isEmpty)
    }

    func testTemplateVariables() {
        let date = DateComponents(calendar: .init(identifier: .gregorian), timeZone: .current, year: 2026, month: 10, day: 21, hour: 9, minute: 5).date!
        let ctx = TemplateVariables.Context(date: date, title: "Besprechung")
        let r = TemplateVariables.apply("# {{titel}}\nAm {{datum:yyyy-MM-dd}} ({{wochentag}}), {{uhrzeit}}\n{{cursor}}\n{{unbekannt}}", context: ctx)
        XCTAssertEqual(TemplateVariables.apply("{{Datum}} KW {{kw}} {{monat}} {{jahr}}", context: ctx).text, "21.10.2026 KW 43 Oktober 2026", "the placeholders older templates use")
        XCTAssertEqual(r.text, "# Besprechung\nAm 2026-10-21 (Mittwoch), 09:05\n\n{{unbekannt}}")
        XCTAssertEqual(r.cursor, ("# Besprechung\nAm 2026-10-21 (Mittwoch), 09:05\n" as NSString).length)
        XCTAssertNil(TemplateVariables.apply("ohne", context: ctx).cursor)
        XCTAssertEqual(DailyNote.title(for: date), "2026-10-21")
    }

    func testMetadataStaysCompatible() throws {
        var m = meta("A")
        m.wikiLinks = ["B"]
        m.properties = [NoteProperty(name: "Status", kind: .status, value: "Offen", options: ["Offen", "Erledigt"])]
        let back = try JSONDecoder().decode(NoteMetadata.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.wikiLinks, ["B"])
        XCTAssertEqual(back.properties?.first?.value, "Offen")
        let old = try JSONDecoder().decode(NoteMetadata.self, from: Data(#"{"id":"8B69FAD9-5077-43A0-AD9C-DAE5020C5F7C","title":"Alt"}"#.utf8))
        XCTAssertNil(old.wikiLinks)
        XCTAssertNil(old.properties)
        let broken = try JSONDecoder().decode(NoteMetadata.self, from: Data(#"{"id":"8B69FAD9-5077-43A0-AD9C-DAE5020C5F7C","properties":"kaputt"}"#.utf8))
        XCTAssertNil(broken.properties, "a broken field never makes the note unreadable")
    }
}

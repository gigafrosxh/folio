import XCTest
@testable import FolioCore

final class AIContextTests: XCTestCase {
    let id = UUID()

    func testPassageSplitting() {
        let text = "# Einkauf\nMilch\nBrot\n\n# Projekt\n" + String(repeating: "Ein langer Satz über das Projekt. ", count: 60)
        let parts = Passages.split(noteID: id, title: "T", text: text, target: 300)
        XCTAssertGreaterThan(parts.count, 3)
        XCTAssertTrue(parts[0].text.hasPrefix("# Einkauf"))
        XCTAssertEqual(parts.map(\.index), Array(0..<parts.count))
        XCTAssertTrue(parts.allSatisfy { $0.text.count <= 360 })
        XCTAssertEqual(Passages.split(noteID: id, title: "T", text: "  \n\n").count, 0)
    }

    func testContextBudget() {
        let ps = (0..<20).map { Passage(noteID: id, noteTitle: "N", index: $0, text: String(repeating: "wort ", count: 100)) }
        let plan = ContextBuilder.plan(ps, budget: 800)
        XCTAssertLessThanOrEqual(plan.usedTokens, 800)
        XCTAssertGreaterThan(plan.passages.count, 0)
        XCTAssertEqual(plan.passages.count + plan.omitted, 20)
        let huge = ContextBuilder.plan([Passage(noteID: id, noteTitle: "N", index: 0, text: String(repeating: "x", count: 20_000))], budget: 500)
        XCTAssertEqual(huge.passages.count, 1, "a too long first passage is shortened, not dropped")
        XCTAssertLessThanOrEqual(huge.usedTokens, 500)
        XCTAssertTrue(ContextBuilder.sourceBlock(plan).hasPrefix("[1] N:\n"))
    }

    func testSearchFindsRelevantPassages() {
        let a = UUID(), b = UUID(), c = UUID()
        let index = PassageIndex([
            Passage(noteID: a, noteTitle: "Rezepte", index: 0, text: "Tomatensoße mit Basilikum und Knoblauch."),
            Passage(noteID: b, noteTitle: "Meeting Montag", index: 0, text: "Wir haben die Rezepten-App und das Budget besprochen."),
            Passage(noteID: c, noteTitle: "Urlaub", index: 0, text: "Flug nach Lissabon am 3. Mai."),
        ])
        let r = index.search("Welche Rezepte habe ich?")
        XCTAssertEqual(r.first?.passage.noteID, a, "title match ranks first")
        XCTAssertTrue(r.contains { $0.passage.noteID == b }, "stemming finds Rezepten")
        XCTAssertFalse(r.contains { $0.passage.noteID == c })
        XCTAssertEqual(index.search("wann geht der Flug nach lissabon").first?.passage.noteID, c)
        XCTAssertTrue(index.search("und oder").isEmpty, "stopwords alone find nothing")
        XCTAssertEqual(PassageIndex.terms("Häuser, Hauses!"), ["haus", "haus"])
    }

    func testCitations() {
        XCTAssertEqual(CitationParser.citations(in: "Laut [2] und [1, 3] sowie [9] … [2]", sourceCount: 3), [2, 1, 3])
        let p = Passage(noteID: id, noteTitle: "N", index: 4, text: "x")
        let linked = CitationParser.linked("Siehe [1] und [5].", sources: [p])
        XCTAssertEqual(linked, "Siehe [[1]](folio://note/\(id.uuidString)?p=4) und [5].")
        let url = URL(string: "folio://note/\(id.uuidString)?p=4")!
        XCTAssertEqual(NoteLink.id(from: url), id)
        XCTAssertEqual(NoteLink.passageIndex(from: url), 4)
    }

    func testTranscriptPersistenceAndRecentTurns() throws {
        let lib = FileManager.default.temporaryDirectory.appendingPathComponent("folio-chat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: lib) }
        let archive = ChatArchive(library: lib)
        var t = ChatTranscript()
        t.messages = [ChatRecord(role: .user, text: "Frage eins"),
                      ChatRecord(role: .assistant, text: "Antwort [1]", sources: [Passage(noteID: id, noteTitle: "N", index: 0, text: "q")], usedTokens: 120)]
        t.extraNotes = [UUID()]
        let key = ChatArchive.key(note: id)
        try archive.save(t, key: key)
        XCTAssertEqual(archive.load(key), t)
        XCTAssertEqual(archive.load("fehlt"), ChatTranscript())
        XCTAssertEqual(t.recentTurns(), "Nutzer: Frage eins\nAssistent: Antwort [1]")
        XCTAssertEqual(t.recentTurns(budget: 7), "Assistent: Antwort [1]", "the newest turns are kept")
        try archive.save(ChatTranscript(), key: key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.directory.appendingPathComponent(key + ".json").path))
        XCTAssertEqual(ChatArchive.key(note: nil), "library")
    }
}

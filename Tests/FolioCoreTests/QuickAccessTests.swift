import XCTest
@testable import FolioCore

final class QuickAccessTests: XCTestCase {
    private var library: URL!
    private func rtf(_ s: String) -> Data? { Data("{\\rtf1 \(s)}".utf8) }

    override func setUpWithError() throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("folio-qa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path)
        try? FileManager.default.removeItem(at: library)
    }

    // MARK: Deep links (#89)

    func testDeepLinks() {
        let id = UUID()
        XCTAssertEqual(try FolioURL.parse(URL(string: "folio://note/\(id.uuidString)?p=3")!).get(), .openNote(id, passage: 3))
        XCTAssertEqual(try FolioURL.parse(URL(string: "folio://capture?text=Hallo%20Welt&target=inbox")!).get(), .capture(text: "Hallo Welt", target: .inbox))
        XCTAssertEqual(try FolioURL.parse(URL(string: "folio://capture")!).get(), .capture(text: nil, target: nil))
        XCTAssertEqual(try FolioURL.parse(URL(string: "folio://search?q=rezept")!).get(), .search("rezept"))
        XCTAssertEqual(try FolioURL.parse(URL(string: "folio://new?title=Idee")!).get(), .newNote(title: "Idee", text: nil))
        XCTAssertEqual(try FolioURL.parse(URL(string: "folio://open")!).get(), .open)
        XCTAssertEqual(FolioURL.parse(URL(string: "folio://note/kaputt")!), .failure(.invalidNoteID("kaputt")))
        XCTAssertEqual(FolioURL.parse(URL(string: "folio://note/")!), .failure(.missingParameter("Notiz-ID")))
        XCTAssertEqual(FolioURL.parse(URL(string: "folio://search")!), .failure(.missingParameter("q")))
        XCTAssertEqual(FolioURL.parse(URL(string: "folio://capture?target=nix")!), .failure(.invalidNoteID("nix")))
        XCTAssertEqual(FolioURL.parse(URL(string: "folio://loeschen")!), .failure(.unknownAction("loeschen")))
        XCTAssertEqual(FolioURL.parse(URL(string: "https://example.com")!), .failure(.notFolio))
        let long = String(repeating: "x", count: 100_001)
        XCTAssertEqual(FolioURL.parse(FolioURL.capture(text: long)), .failure(.tooLong("text")))
        XCTAssertEqual(try FolioURL.parse(FolioURL.capture(text: "a&b=c ü", target: .note(id))).get(), .capture(text: "a&b=c ü", target: .note(id)))
    }

    // MARK: Capture (#87, #93)

    func testCaptureCreatesInboxAndAppends() throws {
        let w = CaptureWriter(library: library)
        var item = CaptureItem(text: "Erster Gedanke https://example.com/a und https://example.com/a", images: [Data([0xFF, 0xD8, 1, 2])])
        try w.deliver(item, to: nil, rtf: rtf, dateText: "heute")
        item = CaptureItem(text: "Zweiter")
        try w.deliver(item, to: nil, rtf: rtf, dateText: "später")
        let inbox = try NoteFile.read(from: w.inboxURL)
        XCTAssertEqual(inbox.meta.title, "Inbox")
        XCTAssertTrue(inbox.meta.pinned)
        XCTAssertEqual(inbox.body.blocks.map(\.kind), [.text, .text, .web, .image, .text])
        XCTAssertEqual(inbox.body.blocks[2].url, "https://example.com/a", "the same link once")
        XCTAssertEqual(inbox.attachments.first?.header.typeIdentifier, "public.jpeg")
        XCTAssertTrue(String(decoding: inbox.body.blocks[4].rtf ?? Data(), as: UTF8.self).contains("Zweiter"))
    }

    func testCaptureIntoNoteKeepsItsContent() throws {
        var b = BlockRecord(kind: .code)
        b.code = "print(1)"
        let note = NoteFile(meta: NoteMetadata(title: "Ziel"), body: NoteBody(blocks: [b]))
        let url = library.appendingPathComponent("Ziel.folio")
        try note.write(to: url)
        try CaptureWriter(library: library).deliver(CaptureItem(text: "Neu", target: .note(note.meta.id)), to: url, rtf: rtf, dateText: "jetzt")
        let back = try NoteFile.read(from: url)
        XCTAssertEqual(back.meta.id, note.meta.id)
        XCTAssertEqual(back.body.blocks.first?.code, "print(1)")
        XCTAssertEqual(back.body.blocks.count, 2)
    }

    func testCaptureFailuresAreClearAndHarmless() throws {
        let gone = CaptureWriter(library: library.appendingPathComponent("Laufwerk fehlt"))
        XCTAssertThrowsError(try gone.deliver(CaptureItem(text: "x"), to: nil, rtf: rtf, dateText: "")) { e in
            XCTAssertEqual(e as? CaptureError, .libraryUnavailable("Laufwerk fehlt"))
            XCTAssertTrue((e as? CaptureError)?.isTemporary == true)
        }
        let w = CaptureWriter(library: library)
        XCTAssertThrowsError(try w.deliver(CaptureItem(text: "x", target: .note(UUID())), to: library.appendingPathComponent("weg.folio"), rtf: rtf, dateText: "")) { e in
            XCTAssertEqual(e as? CaptureError, .noteMissing)
        }
        let broken = library.appendingPathComponent("Kaputt.folio")
        try Data("kaputt".utf8).write(to: broken)
        XCTAssertThrowsError(try w.deliver(CaptureItem(text: "x", target: .note(UUID())), to: broken, rtf: rtf, dateText: ""))
        XCTAssertEqual(try Data(contentsOf: broken), Data("kaputt".utf8), "a damaged note is never overwritten")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: library.path)
        XCTAssertThrowsError(try w.deliver(CaptureItem(text: "x"), to: nil, rtf: rtf, dateText: "")) { e in
            XCTAssertEqual(e as? CaptureError, .notWritable(self.library.lastPathComponent))
        }
    }

    func testQueueKeepsCapturesUntilDelivered() throws {
        let queue = CaptureQueue(directory: library.appendingPathComponent("queue"))
        let a = CaptureItem(text: "A", created: Date(timeIntervalSince1970: 1)), b = CaptureItem(text: "B", images: [Data([1, 2, 3])], created: Date(timeIntervalSince1970: 2))
        try queue.add(b)
        try queue.add(a)
        XCTAssertEqual(queue.items().map(\.text), ["A", "B"])
        // First attempt fails for B: it stays with the reason, A is delivered.
        let n = queue.retry { item in if item.text == "B" { throw CaptureError.libraryUnavailable("X") } }
        XCTAssertEqual(n, 1)
        XCTAssertEqual(queue.items().map(\.text), ["B"])
        XCTAssertNotNil(queue.items().first?.lastError)
        XCTAssertEqual(queue.items().first?.images, [Data([1, 2, 3])])
        XCTAssertEqual(queue.retry { _ in }, 1)
        XCTAssertTrue(queue.items().isEmpty)
    }

    func testCaptureItemBasics() {
        XCTAssertTrue(CaptureItem(text: "  \n").isEmpty)
        XCTAssertFalse(CaptureItem(text: "", images: [Data([1])]).isEmpty)
        XCTAssertEqual(CaptureItem(text: "siehe www.example.com und mailto:a@b.de").links.count, 1)
    }

    // MARK: Switcher (#88)

    func testSwitcherRanking() {
        let entries = [
            SwitcherEntry(kind: .note, title: "Projektplan", detail: "Arbeit", key: "1"),
            SwitcherEntry(kind: .folder, title: "Projekte", detail: "Arbeit/Projekte", key: "/a/p"),
            SwitcherEntry(kind: .tag, title: "#projekt", detail: "3 Notizen", key: "projekt"),
            SwitcherEntry(kind: .note, title: "Einkauf", detail: "", key: "2"),
        ]
        XCTAssertEqual(SwitcherEntry.rank(entries, query: "proj").map(\.kind).first, .note)
        XCTAssertEqual(SwitcherEntry.rank(entries, query: "#proj").map(\.kind), [.tag])
        XCTAssertEqual(SwitcherEntry.rank(entries, query: "/arb").map(\.kind), [.folder])
        XCTAssertEqual(SwitcherEntry.rank(entries, query: "ekf").map(\.key), ["2"])
        XCTAssertEqual(SwitcherEntry.rank(entries, query: "").count, 4)
    }
}

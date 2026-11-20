import XCTest

@testable import FolioCore

/// Milestone 1.11.5: shared save transaction (#310), shared metadata (#311), fault injection (#314).
final class SharedPersistenceTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-shared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func note(_ text: String) -> NoteFile {
        var b = BlockRecord(kind: .code)
        b.code = text
        return NoteFile(meta: NoteMetadata(title: "N"), body: NoteBody(blocks: [b]))
    }

    /// Fails the named operation; everything else goes to the real file system.
    private struct Failing: FileOperations {
        let failing: String
        let real = LocalFileOperations()
        struct Injected: Error {}
        func check(_ op: String) throws { if op == failing { throw Injected() } }
        func fileExists(_ url: URL) -> Bool { real.fileExists(url) }
        func isDirectory(_ url: URL) -> Bool { real.isDirectory(url) }
        func createDirectory(_ url: URL) throws {
            try check("createDirectory")
            try real.createDirectory(url)
        }
        func moveItem(_ source: URL, to target: URL) throws {
            try check("move")
            try real.moveItem(source, to: target)
        }
        func copyItem(_ source: URL, to target: URL) throws {
            try check("copy")
            try real.copyItem(source, to: target)
        }
        func removeItem(_ url: URL) throws {
            try check("remove")
            try real.removeItem(url)
        }
        func write(_ data: Data, to url: URL) throws {
            try check("write")
            try real.write(data, to: url)
        }
        func read(_ url: URL) throws -> Data { try real.read(url) }
    }

    // #310: the contract every platform relies on.
    func testSaveTransactionContract() throws {
        let url = dir.appendingPathComponent("A.folio")
        try note("eins").write(to: url)
        var revisions = SaveRevisions()
        let t = NoteSaveTransaction(history: NoteHistory(library: dir), copySuffix: " (Test)")
        // Normal save: written, version kept, clean.
        var stamp = FileStamp.of(url)
        let two = note("zwei")
        let r1 = try t.save(two, data: two.encoded(), to: url, expected: stamp, revision: 1, current: 1, revisions: &revisions)
        XCTAssertEqual(r1.outcome, .saved)
        XCTAssertTrue(r1.clean)
        XCTAssertEqual(try NoteFile.read(from: url).body.blocks[0].code, "zwei")
        XCTAssertEqual(t.history.versions(of: two.meta.id).count, 1)
        stamp = r1.stamp
        // An older snapshot after a newer one is dropped.
        let old = note("alt")
        XCTAssertEqual(try t.save(old, data: old.encoded(), to: url, expected: stamp, revision: 1, current: 2, revisions: &revisions).outcome, .unchanged)
        // Changed elsewhere: a copy with new ids, the other change stays.
        try note("fremd").write(to: url)
        let mine = note("meins")
        let r2 = try t.save(mine, data: mine.encoded(), to: url, expected: stamp, revision: 2, current: 3, revisions: &revisions)
        guard case .savedAsCopy(let copy) = r2.outcome else { return XCTFail("\(r2.outcome)") }
        XCTAssertFalse(r2.clean, "Eingabe nach dem Snapshot bleibt offen")
        XCTAssertEqual(try NoteFile.read(from: url).body.blocks[0].code, "fremd")
        XCTAssertTrue(copy.lastPathComponent.contains("(Test)"))
        XCTAssertNotEqual(try NoteFile.read(from: copy).meta.id, mine.meta.id)
        // Deleted elsewhere: not recreated.
        try FileManager.default.removeItem(at: url)
        let r3 = try t.save(mine, data: mine.encoded(), to: url, expected: stamp, revision: 3, current: 3, revisions: &revisions)
        guard case .deletedElsewhere = r3.outcome else { return XCTFail("\(r3.outcome)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // #314: an injected write failure leaves the note as it was.
    func testFailedWriteKeepsTheOriginal() throws {
        let url = dir.appendingPathComponent("A.folio")
        try note("original").write(to: url)
        var revisions = SaveRevisions()
        let t = NoteSaveTransaction(history: NoteHistory(library: dir), fs: Failing(failing: "write"), copySuffix: " (Test)")
        let new = note("neu")
        XCTAssertThrowsError(try t.save(new, data: new.encoded(), to: url, expected: FileStamp.of(url), revision: 1, current: 1, revisions: &revisions))
        XCTAssertEqual(try NoteFile.read(from: url).body.blocks[0].code, "original")
        XCTAssertTrue(revisions.mayWrite(1), "ein gescheiterter Versuch zählt nicht als geschrieben")
    }

    // #314: trash steps that fail leave the note in place and no half entry.
    func testTrashFailuresAreClean() throws {
        let note = dir.appendingPathComponent("Notizen/A.folio")
        try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.note("x").write(to: note)
        for op in ["write", "move"] {
            let trash = LibraryTrash(library: dir, fs: Failing(failing: op))
            XCTAssertThrowsError(try trash.moveToTrash(note), op)
            XCTAssertTrue(FileManager.default.fileExists(atPath: note.path), "Notiz bleibt (\(op))")
            XCTAssertTrue(trash.items().isEmpty, "kein halber Eintrag (\(op))")
            XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: trash.directory.path)) ?? [], [])
        }
        let ok = LibraryTrash(library: dir)
        let item = try ok.moveToTrash(note)
        XCTAssertThrowsError(try LibraryTrash(library: dir, fs: Failing(failing: "move")).restore(item))
        XCTAssertEqual(ok.items().count, 1, "bleibt im Papierkorb, wenn das Zurücklegen scheitert")
    }

    // #311: the same blocks give the same metadata, whichever platform builds them.
    func testMetadataRules() {
        let id = UUID(), other = UUID()
        var meta = NoteMetadata(id: id, title: "Alt")
        NoteMetaBuilder.apply(
            [
                .init(kind: .text, content: "— 20. Nov. 2026, 13:00 —\n• Einkauf #privat\nMilch [[Liste]]", noteLinks: [other, id, other]),
                .init(kind: .image, caption: "Bild", altText: "Ein Hund"),
                .init(kind: .pdf, caption: "Rechnung", pdfText: "Betrag"),
                .init(kind: .code, content: "print(1)")
            ], to: &meta)
        XCTAssertEqual(meta.title, "Einkauf #privat")
        XCTAssertEqual(meta.preview, "Milch [[Liste]]")
        XCTAssertEqual(meta.tags, ["privat"])
        XCTAssertEqual(meta.wikiLinks, ["Liste"])
        XCTAssertEqual(meta.links, [other], "eigene Notiz und Doppelte zählen nicht")
        XCTAssertEqual(meta.kinds, ["code", "image", "pdf", "text"])
        XCTAssertTrue(meta.searchText.contains("Ein Hund") && meta.searchText.contains("Betrag") && meta.searchText.contains("print(1)"))
        var empty = NoteMetadata(title: "Bleibt")
        NoteMetaBuilder.apply([.init(kind: .image, caption: "nur Bild")], to: &empty)
        XCTAssertEqual(empty.title, "Bleibt", "ohne Text bleibt der Titel")
    }
}

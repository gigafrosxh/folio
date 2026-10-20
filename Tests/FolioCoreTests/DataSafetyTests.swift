import XCTest
@testable import FolioCore

final class DataSafetyTests: XCTestCase {
    private var library: URL!

    override func setUpWithError() throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("folio-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: library.appendingPathComponent("Notizen"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: library)
    }

    private func note(_ title: String, text: String = "Hallo", attachment: Data? = nil) -> NoteFile {
        var b = BlockRecord(kind: .code)
        b.code = text
        var atts: [FolioArchive.Attachment] = []
        var blocks = [b]
        if let attachment {
            let a = FolioArchive.Attachment(filename: "bild.png", typeIdentifier: "public.png", data: attachment)
            var img = BlockRecord(kind: .image)
            img.attachmentID = a.id
            blocks.append(img)
            atts.append(a)
        }
        return NoteFile(meta: NoteMetadata(title: title), body: NoteBody(blocks: blocks), attachments: atts)
    }

    @discardableResult
    private func write(_ file: NoteFile, _ path: String) throws -> URL {
        let url = library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.write(to: url)
        return url
    }

    // MARK: Retention

    func testRetentionThinsOutOldCopies() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var dates: [Date] = []
        for minutes in stride(from: 0, to: 60 * 24 * 400, by: 30) { dates.append(now.addingTimeInterval(-Double(minutes) * 60)) }
        let policy = RetentionPolicy.versions
        let doomed = Set(policy.toDelete(dates, now: now))
        let kept = dates.filter { !doomed.contains($0) }
        XCTAssertTrue(kept.contains(dates[0]), "newest is always kept")
        // Everything from the last 24 hours survives.
        XCTAssertTrue(dates.filter { now.timeIntervalSince($0) < 86_400 }.allSatisfy { !doomed.contains($0) })
        // Nothing older than a year survives.
        XCTAssertTrue(kept.allSatisfy { now.timeIntervalSince($0) < 365 * 86_400 })
        XCTAssertLessThanOrEqual(kept.count, policy.maxCount)
        // Between 7 and 90 days: at most one per day.
        let daily = kept.filter { (7 * 86_400..<90 * 86_400).contains(now.timeIntervalSince($0)) }
        XCTAssertLessThanOrEqual(daily.count, 84)
        XCTAssertGreaterThan(daily.count, 70)
        XCTAssertEqual(RetentionPolicy.versions.toDelete([now.addingTimeInterval(-500 * 86_400)], now: now), [], "a single old copy is kept")
    }

    func testStampRoundTrip() {
        let d = Date(timeIntervalSince1970: 1_760_000_000.123)
        XCTAssertEqual(Stamp.date(Stamp.string(d))!.timeIntervalSince1970, d.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(Stamp.date("kaputt"))
    }

    // MARK: History

    func testHistoryRecordsThrottlesAndSkipsDuplicates() throws {
        let history = NoteHistory(library: library)
        var file = note("A", text: "eins")
        let id = file.meta.id
        let t0 = Date()
        XCTAssertNotNil(try history.record(file.encoded(), noteID: id, date: t0))
        file.body.blocks[0].code = "zwei"
        XCTAssertNil(try history.record(file.encoded(), noteID: id, date: t0.addingTimeInterval(60)), "within the interval")
        XCTAssertNotNil(try history.record(file.encoded(), noteID: id, date: t0.addingTimeInterval(60), force: true))
        file.meta.modified = Date()   // only the metadata changed
        XCTAssertNil(try history.record(file.encoded(), noteID: id, date: t0.addingTimeInterval(900), force: true), "same content")
        let versions = history.versions(of: id)
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(try history.read(versions[0]).body.blocks[0].code, "zwei")
        XCTAssertEqual(try history.read(versions[1]).body.blocks[0].code, "eins")
        history.removeAll(noteID: id)
        XCTAssertTrue(history.versions(of: id).isEmpty)
    }

    func testSameContentIgnoresKeyOrder() throws {
        let meta = try JSONEncoder().encode(NoteMetadata(title: "A"))
        let a = try FolioArchive(meta: meta, body: Data(#"{"blocks":[{"id":"8B69FAD9-5077-43A0-AD9C-DAE5020C5F7C","kind":"code","code":"x"}]}"#.utf8)).encoded()
        let b = try FolioArchive(meta: meta, body: Data(#"{"blocks":[{"code":"x","kind":"code","id":"8B69FAD9-5077-43A0-AD9C-DAE5020C5F7C"}]}"#.utf8)).encoded()
        let c = try FolioArchive(meta: meta, body: Data(#"{"blocks":[{"code":"y","kind":"code","id":"8B69FAD9-5077-43A0-AD9C-DAE5020C5F7C"}]}"#.utf8)).encoded()
        XCTAssertTrue(NoteHistory.sameContent(a, b), "same body in another key order (#98)")
        XCTAssertFalse(NoteHistory.sameContent(a, c))
        var file = note("A", text: "eins")
        file.meta.modified = Date()
        XCTAssertEqual(try FolioArchive.decode(file.encoded()).body, try FolioArchive.decode(file.encoded()).body,
                       "a note always encodes to the same bytes")
    }

    // MARK: Trash

    func testTrashMoveRestoreAndDelete() throws {
        let trash = LibraryTrash(library: library)
        let history = NoteHistory(library: library)
        let file = note("Einkauf")
        let url = try write(file, "Notizen/Einkauf.folio")
        try history.record(file.encoded(), noteID: file.meta.id)

        let item = try trash.moveToTrash(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(item.originalPath, "Notizen/Einkauf.folio")
        XCTAssertEqual(item.noteIDs, [file.meta.id])
        XCTAssertEqual(trash.items().map(\.id), [item.id])

        // The place is taken in the meantime: restore under a new name, nothing is overwritten.
        try write(note("Anderes"), "Notizen/Einkauf.folio")
        let restored = try trash.restore(item)
        XCTAssertEqual(restored.lastPathComponent, "Einkauf 2.folio")
        XCTAssertEqual(try NoteFile.read(from: restored).meta.id, file.meta.id)
        XCTAssertTrue(trash.items().isEmpty)

        let again = try trash.moveToTrash(restored)
        try trash.deletePermanently(again, history: history)
        XCTAssertTrue(trash.items().isEmpty)
        XCTAssertTrue(history.versions(of: file.meta.id).isEmpty, "versions go with it")
        XCTAssertThrowsError(try trash.restore(again))
    }

    func testTrashFolderRecreatesMissingParentsAndPurges() throws {
        let trash = LibraryTrash(library: library)
        try write(note("Eins"), "Projekte/Alt/Eins.folio")
        try write(note("Zwei"), "Projekte/Alt/Unter/Zwei.folio")
        let item = try trash.moveToTrash(library.appendingPathComponent("Projekte/Alt"), date: Date(timeIntervalSinceNow: -40 * 86_400))
        XCTAssertTrue(item.isFolder)
        XCTAssertEqual(item.noteCount, 2)
        try FileManager.default.removeItem(at: library.appendingPathComponent("Projekte"))
        let restored = try trash.restore(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.appendingPathComponent("Unter/Zwei.folio").path))

        try trash.moveToTrash(restored, date: Date(timeIntervalSinceNow: -40 * 86_400))
        try trash.moveToTrash(try write(note("Neu"), "Notizen/Neu.folio"))
        XCTAssertEqual(trash.purge(olderThan: 30), 1)
        XCTAssertEqual(trash.items().map(\.title), ["Neu"])
        XCTAssertThrowsError(try trash.moveToTrash(URL(fileURLWithPath: "/tmp/fremd.folio")))
    }

    // MARK: Diagnostics

    func testHealthyFile() throws {
        let report = FolioDiagnostics.diagnose(try note("Gesund", attachment: Data(repeating: 7, count: 500)).encoded())
        XCTAssertTrue(report.isHealthy, report.summary)
        XCTAssertEqual(report.blocks.count, 2)
        XCTAssertEqual(report.attachments.count, 1)
    }

    func testFlippedByteInAttachmentKeepsText() throws {
        var data = try note("Kaputt", text: "wichtiger Text", attachment: Data((0..<4000).map { UInt8($0 % 251) })).encoded()
        data[data.count - 40] ^= 0xFF   // inside the attachment's compressed data
        XCTAssertThrowsError(try NoteFile.decode(data))
        let report = FolioDiagnostics.diagnose(data)
        XCTAssertFalse(report.isHealthy)
        XCTAssertTrue(report.problems.contains { $0.message.contains("Prüfsumme") })
        XCTAssertEqual(report.blocks.first?.code, "wichtiger Text")
        let rescued = try XCTUnwrap(report.salvagedFile())
        XCTAssertEqual(rescued.meta.title, "Kaputt (gerettet)")
        // The rescued note is a normal, readable note.
        XCTAssertEqual(try NoteFile.decode(rescued.encoded()).body.blocks.first?.code, "wichtiger Text")
    }

    func testTruncatedAndForeignFiles() throws {
        let data = try note("Abgeschnitten", text: String(repeating: "x", count: 5000)).encoded()
        let cut = FolioDiagnostics.diagnose(data.prefix(data.count / 2))
        XCTAssertFalse(cut.isHealthy)
        XCTAssertNotNil(cut.meta, "metadata comes first and survives")
        XCTAssertEqual(FolioDiagnostics.diagnose(Data()).summary.contains("leer"), true)
        XCTAssertTrue(FolioDiagnostics.diagnose(Data("Hallo Welt".utf8)).summary.contains("keine Folio-Notiz"))
        XCTAssertFalse(FolioDiagnostics.diagnose(Data("Hallo Welt".utf8)).canSalvage)
    }

    func testFingerprintTracksChanges() throws {
        let url = try write(note("F"), "Notizen/F.folio")
        let a = try XCTUnwrap(FileFingerprint.of(url))
        XCTAssertEqual(a, FileFingerprint(data: try Data(contentsOf: url)))
        try write(note("F", text: "anders"), "Notizen/F.folio")
        XCTAssertNotEqual(FileFingerprint.of(url), a)
        XCTAssertNil(FileFingerprint.of(library.appendingPathComponent("fehlt.folio")))
    }

    func testTextDiff() {
        let d = TextDiff.lines("a\nb\nc", "a\nc\nd")
        XCTAssertEqual(d.map(\.kind), [.same, .removed, .same, .added])
        XCTAssertEqual(d.map(\.text), ["a", "b", "c", "d"])
    }

    // MARK: Backups

    func testBackupCreateVerifyRestorePrune() throws {
        try write(note("Eins"), "Notizen/Eins.folio")
        try write(note("Zwei", attachment: Data(repeating: 1, count: 300)), "Projekte/Zwei.folio")
        try write(note("Versteckt"), ".folio/history/x/y.folio")   // Folio's own data is not backed up
        let dir = library.deletingLastPathComponent().appendingPathComponent("folio-backups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let backup = try LibraryBackup.create(library: library, in: dir)
        XCTAssertEqual(LibraryBackup.list(in: dir).map(\.url.lastPathComponent), [backup.url.lastPathComponent])
        let check = try LibraryBackup.verify(backup.url)
        XCTAssertEqual(check, BackupCheck(notes: 2, damaged: []))

        let restored = try LibraryBackup.restore(backup.url, into: library, name: "Wiederhergestellt")
        XCTAssertEqual(try NoteFile.read(from: restored.appendingPathComponent("Projekte/Zwei.folio")).meta.title, "Zwei")
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.appendingPathComponent(".folio").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.appendingPathComponent("Folio-Backup.json").path))

        // Old backups are thinned out.
        for days in [3.5, 3.501, 20, 100] {
            _ = try LibraryBackup.create(library: library, in: dir, date: Date(timeIntervalSinceNow: -days * 86_400))
        }
        let removed = LibraryBackup.prune(in: dir)
        XCTAssertEqual(removed.count, 2, "two copies on the same day and one older than 90 days")
        XCTAssertEqual(LibraryBackup.list(in: dir).count, 3)
    }

    func testBackupDetectsDamagedNote() throws {
        var data = try note("Kaputt", text: String(repeating: "y", count: 2000)).encoded()
        data[data.count - 10] ^= 0x55
        try data.write(to: library.appendingPathComponent("Notizen/Kaputt.folio"))
        let dir = library.appendingPathComponent("..").appendingPathComponent("folio-backups-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: dir) }
        let check = try LibraryBackup.verify(try LibraryBackup.create(library: library, in: dir).url)
        XCTAssertEqual(check.damaged, ["Notizen/Kaputt.folio"])
    }

    func testBackupOfEmptyLibrary() throws {
        let empty = library.appendingPathComponent("leer")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let dir = library.appendingPathComponent("backups")
        let backup = try LibraryBackup.create(library: empty, in: dir)
        XCTAssertEqual(try LibraryBackup.verify(backup.url).notes, 0)
    }
}

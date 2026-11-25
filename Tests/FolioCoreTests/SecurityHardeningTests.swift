import XCTest

@testable import FolioCore

/// Milestone 1.11.1: trash paths (#280, #281), backup import (#282), memory budget (#283), attachment headers (#284)
/// and redaction (#285, #286).
final class SecurityHardeningTests: XCTestCase {
    private var dir: URL!
    private var library: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-sec-\(UUID().uuidString)")
        library = dir.appendingPathComponent("Bibliothek")
        try FileManager.default.createDirectory(at: library.appendingPathComponent("Notizen"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func writeNote(_ url: URL) throws {
        try NoteFile(meta: NoteMetadata(title: "N"), body: NoteBody()).write(to: url)
    }

    // #280
    func testForgedTrashPathIsRefusedAndItemStays() throws {
        let trash = LibraryTrash(library: library)
        let note = library.appendingPathComponent("Notizen/A.folio")
        try writeNote(note)
        var item = try trash.moveToTrash(note)
        let content = trash.contentURL(of: item)
        for forged in ["../draussen.folio", "/tmp/x.folio", "Notizen/../../x.folio", ""] {
            item.originalPath = forged
            XCTAssertThrowsError(try trash.restore(item), forged)
            XCTAssertTrue(FileManager.default.fileExists(atPath: content.path), "bleibt im Papierkorb")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("draussen.folio").path))
        item.originalPath = "Notizen/A.folio"
        XCTAssertEqual(try trash.restore(item).lastPathComponent, "A.folio")
    }

    // #372
    func testFolderNamedInfoJsonGoesToTheTrashAndBack() throws {
        let folder = library.appendingPathComponent("Notizen/info.json", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeNote(folder.appendingPathComponent("N.folio"))
        let trash = LibraryTrash(library: library)
        let item = try trash.moveToTrash(folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(trash.items().map(\.id), [item.id])
        let back = try trash.restore(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: back.appendingPathComponent("N.folio").path))
        // An item trashed before 1.11.17 (content next to info.json) is still found.
        let note = library.appendingPathComponent("Notizen/Alt.folio")
        try writeNote(note)
        let old = try trash.moveToTrash(note)
        let holder = trash.directory.appendingPathComponent(old.id.uuidString)
        try FileManager.default.moveItem(at: holder.appendingPathComponent("content/Alt.folio"), to: holder.appendingPathComponent("Alt.folio"))
        try FileManager.default.removeItem(at: holder.appendingPathComponent("content"))
        XCTAssertTrue(trash.items().contains { $0.id == old.id })
        XCTAssertEqual(try trash.restore(old).lastPathComponent, "Alt.folio")
    }

    // #281
    func testSymbolicFolderLinks() throws {
        let outside = dir.appendingPathComponent("Fremd")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try writeNote(outside.appendingPathComponent("F.folio"))
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("Link"), withDestinationURL: outside)
        let inner = library.appendingPathComponent("Notizen/Unter")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try writeNote(inner.appendingPathComponent("I.folio"))
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("Innen"), withDestinationURL: inner)
        let trash = LibraryTrash(library: library)
        XCTAssertThrowsError(try trash.moveToTrash(library.appendingPathComponent("Link/F.folio"))) {
            XCTAssertEqual(($0 as? LibraryTrash.TrashError).map { "\($0)" }, "outsideLibrary")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("F.folio").path))
        XCTAssertNoThrow(try trash.moveToTrash(library.appendingPathComponent("Innen/I.folio")), "Link innerhalb der Bibliothek ist erlaubt")
        XCTAssertNil(trash.target(for: "Link/F.folio"), "Wiederherstellen über einen Link nach draußen")
        XCTAssertNotNil(trash.target(for: "Neu/Ordner/X.folio"), "fehlende Ordner innerhalb gehen")
    }

    #if os(macOS)
        // #282
        func testUnsafeBackupArchivesAreRefused() throws {
            let entries = [LibraryBackup.Entry(size: 10, path: "A.folio")]
            XCTAssertNoThrow(try LibraryBackup.check(entries, freeSpace: 1 << 30))
            XCTAssertThrowsError(try LibraryBackup.check([.init(size: 1, path: "../x")], freeSpace: 1 << 30))
            XCTAssertThrowsError(try LibraryBackup.check([.init(size: 1, path: "/etc/x")], freeSpace: 1 << 30))
            XCTAssertThrowsError(try LibraryBackup.check([.init(size: 2 << 30, path: "big")], freeSpace: 1 << 30), "größer als der freie Platz")
            XCTAssertThrowsError(try LibraryBackup.check([.init(size: .max, path: "a"), .init(size: .max, path: "b")], freeSpace: .max))
            // #374: a sum that wraps around to a small value is still refused.
            XCTAssertThrowsError(try LibraryBackup.check([.init(size: .max, path: "a"), .init(size: 2, path: "b")], freeSpace: .max))
            XCTAssertNoThrow(try LibraryBackup.check([.init(size: 600, path: "a"), .init(size: 400, path: "b")], freeSpace: 1000))
            XCTAssertThrowsError(try LibraryBackup.check([.init(size: 600, path: "a"), .init(size: 401, path: "b")], freeSpace: 1000))
            XCTAssertThrowsError(try LibraryBackup.check(Array(repeating: .init(size: 0, path: "a"), count: LibraryBackup.maxEntries + 1), freeSpace: .max))
            // A real archive: its table of contents is read, a link out of it is dropped, a broken file refused.
            let src = dir.appendingPathComponent("src")
            try FileManager.default.createDirectory(at: src.appendingPathComponent("Ordner"), withIntermediateDirectories: true)
            try writeNote(src.appendingPathComponent("Ordner/N.folio"))
            try FileManager.default.createSymbolicLink(at: src.appendingPathComponent("raus"), withDestinationURL: URL(fileURLWithPath: "/etc"))
            let zip = dir.appendingPathComponent("t.zip")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.arguments = ["-qry", zip.path, "."]
            p.currentDirectoryURL = src
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(Set(try LibraryBackup.contents(of: zip).map(\.path)), ["Ordner/", "Ordner/N.folio", "raus"])
            let out = dir.appendingPathComponent("out")
            try LibraryBackup.unpack(zip, to: out)
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("Ordner/N.folio").path))
            XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: out.appendingPathComponent("raus").path), "Link nach draußen entfernt")
            let broken = dir.appendingPathComponent("kaputt.zip")
            try Data("kein zip".utf8).write(to: broken)
            XCTAssertThrowsError(try LibraryBackup.unpack(broken, to: dir.appendingPathComponent("out2")))
        }
    #endif

    // #283
    func testMemoryBudgetFollowsTheMac() {
        XCTAssertLessThanOrEqual(ArchiveLimits.maxTotal, 4 << 30)
        XCTAssertLessThanOrEqual(ArchiveLimits.maxTotal, ProcessInfo.processInfo.physicalMemory / 2)
        XCTAssertGreaterThanOrEqual(ArchiveLimits.maxTotal, ArchiveLimits.maxSection, "eine große Notiz bleibt möglich")
    }

    // #284
    func testOverlongAttachmentHeaderIsAFormatError() throws {
        let long = String(repeating: "x", count: Int(ArchiveLimits.maxAttachmentHeader))
        let file = NoteFile(
            meta: NoteMetadata(title: "N"), body: NoteBody(), attachments: [FolioArchive.Attachment(filename: long, typeIdentifier: "t", data: Data())])
        XCTAssertThrowsError(try file.encoded()) { XCTAssertEqual($0 as? FolioFormatError, .tooLarge) }
        // A forged file claiming a huge header: the length field right before the header JSON is patched.
        let note = NoteFile(meta: NoteMetadata(title: "N"), body: NoteBody(), attachments: [.init(filename: "a", typeIdentifier: "t", data: Data())])
        var payload = Data(try note.encoded().dropLast(4))
        let marker = try XCTUnwrap(payload.range(of: Data(#"{"#.utf8), options: .backwards, in: 0..<payload.count))
        let headerStart = try XCTUnwrap(payload[..<marker.lowerBound].lastIndex(of: UInt8(ascii: "{")).map { _ in marker.lowerBound })
        withUnsafeBytes(of: UInt32.max.littleEndian) { payload.replaceSubrange(headerStart - 4..<headerStart, with: $0) }
        var w = ByteWriter()
        w.append(payload)
        w.append(CRC32.checksum(payload))
        XCTAssertThrowsError(try FolioArchive.decode(w.data)) { XCTAssertEqual($0 as? FolioFormatError, .tooLarge) }
    }

    // #285, #286
    func testRedaction() {
        let env = ["PGPASSWORD": "ab", "GITHUB_TOKEN": "ghp_123456", "OPENAI_API_KEY": "sk-abc", "HOME": "/Users/x", "MY_SECRET": "geheim"]
        let secrets = SecretRedaction.secrets(in: env)
        XCTAssertEqual(Set(secrets), ["ab", "ghp_123456", "sk-abc", "geheim"])
        let text = "password=ab; Token ghp_123456 und sk-abc, \"pwd\": \"ab\" – ein abgabe-Text bleibt, geheim auch weg"
        let out = SecretRedaction.redact(text, secrets: secrets)
        XCTAssertFalse(out.contains("ghp_123456") || out.contains("sk-abc") || out.contains("geheim"))
        XCTAssertFalse(out.contains("password=ab") || out.contains("\"pwd\": \"ab\""), out)
        XCTAssertTrue(out.contains("abgabe-Text"), "normaler Text bleibt lesbar")
        XCTAssertEqual(SecretRedaction.redact("postgres://anna:x@db:5432/app", secrets: []), "postgres://anna:••••••@db:5432/app")
    }
}

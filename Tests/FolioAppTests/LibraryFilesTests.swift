import XCTest
@testable import Folio
@testable import FolioCore

/// The library's file operations without UI state (#216): success and failure, duplicate ids.
final class LibraryFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("libfiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    func testPrepareCreatesFirstFolderOnlyWhenEmpty() {
        let files = LibraryFiles(root: root)
        files.prepare()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Notizen").path))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("Notizen"))
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Eigenes"), withIntermediateDirectories: true)
        files.prepare()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Notizen").path))
    }

    func testFolderOperations() throws {
        let files = LibraryFiles(root: root)
        let made = try files.createFolder(named: "Pro/jekt").get()
        XCTAssertEqual(made.lastPathComponent, "Pro-jekt")
        XCTAssertEqual(files.createFolder(named: "Pro/jekt").failureMessage?.hasPrefix("Ordner konnte nicht angelegt werden"), true, "exists already")
        let renamed = try files.renameFolder(made, to: "Archiv").get()
        XCTAssertEqual(renamed.lastPathComponent, "Archiv")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Belegt"), withIntermediateDirectories: true)
        XCTAssertNotNil(files.renameFolder(renamed, to: "Belegt").failureMessage, "target taken")
        _ = try files.trashFolder(renamed).get()
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertEqual(LibraryTrash(library: root).items().count, 1)
        XCTAssertNotNil(files.trashFolder(root.appendingPathComponent("gibt es nicht")).failureMessage)
    }

    func testReadOnlyParentRefusesNewFolder() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        XCTAssertNotNil(LibraryFiles(root: root).createFolder(named: "X").failureMessage)
    }

    func testDuplicateIDsAreRenewed() throws {
        let id = UUID()
        let a = root.appendingPathComponent("A.folio"), b = root.appendingPathComponent("B.folio")
        for url in [a, b] { try NoteFile(meta: NoteMetadata(id: id, title: url.lastPathComponent), body: NoteBody()).write(to: url) }
        let found = [a, b].map { NoteRef(meta: try! NoteFile.readMetadata(at: $0), url: $0) }
        let (refs, failure) = LibraryFiles(root: root).renewingDuplicateIDs(found, known: [id: a])
        XCTAssertNil(failure)
        XCTAssertEqual(Set(refs.map(\.id)).count, 2)
        XCTAssertEqual(refs.first { $0.url == a }?.id, id, "the known file keeps its id")
        XCTAssertNotEqual(try NoteFile.readMetadata(at: b).id, id, "the copy was rewritten with a new id")
    }

    func testDuplicateThatCannotBeRewrittenIsReported() throws {
        let id = UUID()
        let a = root.appendingPathComponent("A.folio"), b = root.appendingPathComponent("B.folio")
        for url in [a, b] { try NoteFile(meta: NoteMetadata(id: id, title: url.lastPathComponent), body: NoteBody()).write(to: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        let found = [a, b].map { NoteRef(meta: try! NoteFile.readMetadata(at: $0), url: $0) }
        let (refs, failure) = LibraryFiles(root: root).renewingDuplicateIDs(found, known: [id: a])
        XCTAssertEqual(refs.map(\.url), [a], "the copy stays out of the list")
        XCTAssertEqual(failure, .duplicatesNotRenewed(["B.folio"]))
    }

    func testUniqueNames() throws {
        let first = LibraryFiles.uniqueURL(in: root, base: "Notiz")
        try Data().write(to: first)
        XCTAssertEqual(LibraryFiles.uniqueURL(in: root, base: "Notiz").lastPathComponent, "Notiz 2.folio")
        XCTAssertEqual(LibraryFiles.sanitize("..a/b:c"), "a-b-c")
    }
}

private extension Result where Failure == LibraryFiles.Failure {
    var failureMessage: String? { if case .failure(let f) = self { return f.localizedDescription } else { return nil } }
}

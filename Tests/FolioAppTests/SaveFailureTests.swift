import AppKit
import XCTest
import FolioCore
@testable import Folio

/// Unsaved text and other versions survive failed writes and repeated outside changes (#183–#186, 1.4.3).
@MainActor
final class SaveFailureTests: XCTestCase {
    private var store: NoteStore { NoteStore.shared }
    private var folder: URL!

    override func setUp() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["FOLIO_LIBRARY"] == nil, "needs a throwaway library")
        folder = try XCTUnwrap(store.createFolder(named: "Speichern-\(UUID().uuidString.prefix(6))"))
        store.lastError = nil
    }

    override func tearDown() async throws {
        guard let folder else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        if let c = store.conflict { store.conflict = nil; store.closeDocument(c.doc.id) }
        for id in store.tabs { store.documents[id]?.saveNow() }
        store.selectedNoteID = nil
        try? FileManager.default.removeItem(at: folder)
        store.sidebarSelection = .all
        store.lastError = nil
        store.reload()
    }

    /// A note open in the editor whose first text block holds `text`, saved.
    private func openNote(_ title: String, text: String) throws -> NoteDocument {
        var b = BlockRecord(kind: .text)
        b.rtf = RichTextCodec.rtfData(from: NSAttributedString(string: text, attributes: ThemeManager.shared.bodyAttributes))
        var meta = NoteMetadata(title: title, searchText: text)
        meta.tags = TagParser.tags(in: text)
        let url = store.uniqueURL(in: folder, base: title)
        try NoteFile(meta: meta, body: NoteBody(blocks: [b])).write(to: url)
        store.reload()
        store.selectedNoteID = meta.id
        return try XCTUnwrap(store.documents[meta.id])
    }

    private func type(_ doc: NoteDocument, _ text: String) {
        doc.blocks.first { $0.kind == .text }!.storage.append(NSAttributedString(string: text))
        doc.markDirty()
    }

    private func locked(_ body: () async throws -> Void) async rethrows {
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        try await body()
    }

    private func shows(_ id: UUID, _ marker: String) -> Bool {
        store.documents[id]?.blocks.contains { $0.storage.string.contains(marker) } == true
    }

    private func onDisk(_ doc: NoteDocument) -> String { (try? NoteFile.read(from: doc.url)).map(NoteText.of) ?? "" }

    private func inHistory(_ id: UUID, _ marker: String) -> Bool {
        store.history.versions(of: id).contains { ((try? store.history.read($0)).map(NoteText.of) ?? "").contains(marker) }
    }

    /// Changes the file on disk behind the editor's back (with a new modification time).
    private func changeOutside(_ doc: NoteDocument, _ code: String) async throws {
        try await Task.sleep(for: .milliseconds(1100))
        var theirs = try NoteFile.read(from: doc.url)
        var block = BlockRecord(kind: .code)
        block.code = code
        theirs.body.blocks.append(block)
        try theirs.write(to: doc.url)
    }

    func testClosingATabThatCannotBeSavedKeepsIt() async throws {
        // #183
        let doc = try openNote("Schliessen", text: "Anfang")
        let id = doc.id
        type(doc, " UNGESICHERT_183")
        await locked { store.closeTab(id) }
        XCTAssertTrue(store.tabs.contains(id), "the tab stays")
        XCTAssertTrue(shows(id, "UNGESICHERT_183"))
        XCTAssertNotNil(store.lastError)
        store.lastError = nil
        store.closeTab(id)
        XCTAssertFalse(store.tabs.contains(id), "with a writable folder it closes")
        XCTAssertTrue(onDisk(doc).contains("UNGESICHERT_183"), "and the text was saved on the way")
    }

    func testReplacingTheTabOfANoteThatCannotBeSavedKeepsIt() async throws {
        // #183, the other path: clicking another note replaces the active tab and releases the old document.
        let other = try openNote("Andere", text: "x").id
        let doc = try openNote("Ersetzt", text: "Anfang")
        type(doc, " UNGESICHERT_183B")
        await locked { store.selectedNoteID = other }
        XCTAssertTrue(shows(doc.id, "UNGESICHERT_183B"), "the document is still open")
        XCTAssertTrue(store.tabs.contains(doc.id), "in a tab of its own")
        store.lastError = nil
    }

    func testTagEditDoesNotReloadANoteWithUnsavedChanges() async throws {
        // #184
        let doc = try openNote("Tagnotiz", text: "Text #speicherprobe")
        type(doc, " UNGESICHERT_184")
        await locked { await store.editTag("speicherprobe", to: "umbenannt") }
        XCTAssertTrue(shows(doc.id, "UNGESICHERT_184"), "the unsaved text stays")
        XCTAssertTrue(store.tagEdit?.failures.contains { $0.contains("Tagnotiz") } == true, "and the note is listed as not changed")
        store.tagEdit = nil
        store.lastError = nil
    }

    func testUnsavedNotesBlockQuitLibrarySwitchAndDeletion() async throws {
        // #189, #190, #191, #192
        let doc = try openNote("Festgehalten", text: "Anfang")
        let (id, url) = (doc.id, doc.url)
        type(doc, " UNGESICHERT_144")
        let root = store.rootURL
        try await locked {
            XCTAssertEqual(store.unsavedAfterSaving().map(\.id), [id], "the quit question sees the note (#189)")

            XCTAssertFalse(store.setLibrary(root.appendingPathComponent("../andere-\(UUID().uuidString.prefix(4))").standardizedFileURL))
            XCTAssertEqual(store.rootURL, root, "the library did not change (#190)")
            XCTAssertTrue(shows(id, "UNGESICHERT_144"))

            store.delete(id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the note was not moved to the trash (#191)")
            XCTAssertTrue(shows(id, "UNGESICHERT_144"))

            store.deleteFolder(folder)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "the folder stays (#192)")
            XCTAssertTrue(shows(id, "UNGESICHERT_144"))
        }
        store.lastError = nil
        XCTAssertTrue(store.unsavedAfterSaving().isEmpty, "with a writable folder everything saves")
        XCTAssertTrue(onDisk(doc).contains("UNGESICHERT_144"))
    }

    func testFailedFolderDeletionKeepsTheNotesOpen() async throws {
        // #192: the notes are saved, but the folder cannot be moved to the trash.
        let doc = try openNote("Bleibt offen", text: "Inhalt")
        let parent = folder.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        store.deleteFolder(folder)
        XCTAssertNotNil(store.documents[doc.id], "the note stays open when the folder could not be deleted")
        XCTAssertNotNil(store.lastError)
        store.lastError = nil
    }

    func testRestoreKeepsTheCurrentStateWhenItCannotBeSaved() async throws {
        // #193
        let doc = try openNote("Wiederherstellen", text: "ALT_193")
        _ = try store.history.record(try doc.makeFile().encoded(), noteID: doc.id, force: true)
        let first = try XCTUnwrap(store.history.versions(of: doc.id).first)
        type(doc, " NEU_193")
        doc.saveNow()
        let historyDir = store.history.directory.appendingPathComponent(doc.id.uuidString)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: historyDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: historyDir.path) }
        store.restoreVersion(first, of: doc)
        XCTAssertTrue(onDisk(doc).contains("NEU_193"), "nothing replaced the current state")
        XCTAssertNotNil(store.lastError)
        store.lastError = nil
    }

    /// The first line changed and not saved yet: saving renames the file.
    private func retitled(_ title: String) throws -> NoteDocument {
        let doc = try openNote(title, text: "\(title)\nText")
        let block = try XCTUnwrap(doc.blocks.first { $0.kind == .text })
        block.storage.replaceCharacters(in: NSRange(location: 0, length: (title as NSString).length), with: title + " Neu")
        doc.markDirty()
        return doc
    }

    func testDuplicateDeleteAndMoveRightAfterATitleChange() throws {
        // #196
        let a = try retitled("Dupli")
        store.lastError = nil
        let copy = try XCTUnwrap(store.duplicate(a.id), store.lastError ?? "")
        XCTAssertTrue(onDisk(a).contains("Dupli Neu"))
        XCTAssertTrue(((try? NoteFile.read(from: copy.url)).map(NoteText.of) ?? "").contains("Dupli Neu"), "the copy has the new title")

        let b = try retitled("Weg")
        store.delete(b.id)
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.notes.contains { $0.id == b.id })

        let c = try retitled("Rueber")
        let target = try XCTUnwrap(store.createFolder(named: "Ziel", in: folder))
        store.move(c.id, to: target)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.notes.first { $0.id == c.id }?.folderURL.standardizedFileURL, target.standardizedFileURL)
    }

    func testAnOpenConflictKeepsTheNoteUnsaved() async throws {
        // #206
        let doc = try openNote("Konfliktbleibt", text: "Anfang")
        try await changeOutside(doc, "AUSSEN_206")
        type(doc, " MEIN_206")
        store.checkExternalChange()
        XCTAssertNotNil(store.conflict)
        type(doc, " WEITER_206")
        doc.saveNow()
        XCTAssertTrue(doc.isDirty, "writing on during a conflict is still unsaved")
        XCTAssertEqual(store.unsavedAfterSaving().map(\.id), [doc.id], "the quit question sees it")
        store.closeTab(doc.id)
        XCTAssertTrue(store.tabs.contains(doc.id), "the tab stays")
        XCTAssertTrue(store.lastError?.contains("Konflikt") == true)
        store.lastError = nil
        store.resolve(try XCTUnwrap(store.conflict), .keepMine)
        XCTAssertFalse(store.documents[doc.id]?.isDirty ?? true)
        XCTAssertTrue(onDisk(doc).contains("WEITER_206"))
    }

    func testBackupSaysWhichNewestChangesItLacks() async throws {
        // #211
        let doc = try openNote("Backupkonflikt", text: "Anfang")
        try await changeOutside(doc, "AUSSEN_211")
        type(doc, " NUR_IM_EDITOR")
        store.checkExternalChange()
        XCTAssertNotNil(store.conflict)
        let backups = BackupManager.shared
        backups.backupNow()
        for _ in 0..<200 where backups.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(backups.isRunning)
        XCTAssertTrue(backups.lastError?.contains("Backupkonflikt") == true, backups.lastError ?? backups.status ?? "–")
        store.resolve(try XCTUnwrap(store.conflict), .keepMine)
        backups.backupNow()
        for _ in 0..<200 where backups.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(backups.lastError, "with everything saved there is no warning")
    }

    func testCaptureIntoAnOpenNoteThatCannotBeSavedSaysSo() async throws {
        // #207
        let doc = try openNote("Ziel", text: "Inhalt")
        var result: (ok: Bool, message: String) = (false, "")
        await locked { result = CaptureService.shared.save(CaptureItem(text: "ERFASST_207", target: .note(doc.id))) }
        XCTAssertFalse(result.message.hasPrefix("In der Notiz gespeichert"), result.message)
        XCTAssertTrue(result.message.contains("noch nicht gesichert"), result.message)
        XCTAssertTrue(shows(doc.id, "ERFASST_207"))
        store.lastError = nil
        doc.saveNow()
        XCTAssertTrue(onDisk(doc).contains("ERFASST_207"))
        XCTAssertTrue(CaptureService.shared.save(CaptureItem(text: "ZWEI", target: .note(doc.id))).message.hasPrefix("In der Notiz gespeichert"))
    }

    func testKeepMineSavesTheNewestOutsideVersion() async throws {
        // #185
        let doc = try openNote("Zweimal", text: "Anfang")
        try await changeOutside(doc, "AUSSEN_EINS")
        type(doc, " MEIN_185")
        store.checkExternalChange()
        let conflict = try XCTUnwrap(store.conflict)
        try await changeOutside(doc, "AUSSEN_ZWEI")
        store.resolve(conflict, .keepMine)
        XCTAssertTrue(inHistory(doc.id, "AUSSEN_EINS"))
        XCTAssertTrue(inHistory(doc.id, "AUSSEN_ZWEI"), "the second outside version is kept too")
        XCTAssertTrue(onDisk(doc).contains("MEIN_185"))
    }

    func testTakeTheirsKeepsTheConflictWhenTheHistoryCannotBeWritten() async throws {
        // #186
        let doc = try openNote("Verlauf", text: "Anfang")
        try await changeOutside(doc, "AUSSEN_186")
        type(doc, " MEIN_186")
        store.checkExternalChange()
        let conflict = try XCTUnwrap(store.conflict)
        let historyDir = store.history.directory
        try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: historyDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: historyDir.path) }
        // The note's own history folder may exist already; lock it too.
        let noteDir = historyDir.appendingPathComponent(doc.id.uuidString)
        if FileManager.default.fileExists(atPath: noteDir.path) { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: noteDir.path) }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: noteDir.path) }
        store.resolve(conflict, .takeTheirs)
        XCTAssertNotNil(store.conflict, "the conflict stays open")
        XCTAssertTrue(shows(doc.id, "MEIN_186"), "the own version stays in the editor")
        XCTAssertNotNil(store.lastError)
        store.lastError = nil
    }
}

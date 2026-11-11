import AppKit
import PDFKit
import XCTest
import FolioCore
@testable import Folio

/// Sorting, manual order, favorites and smart views in the store, against the test library (#13, #14, #15).
@MainActor
final class OrganizationStoreTests: XCTestCase {
    private var store: NoteStore { NoteStore.shared }
    private var folder: URL!
    private var before = LibraryOrganization()

    override func setUp() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["FOLIO_LIBRARY"] == nil, "needs a throwaway library")
        before = store.organization
        store.organization = LibraryOrganization()
        store.searchText = ""
        store.searchFilter = SearchFilter()
        folder = try XCTUnwrap(store.createFolder(named: "Ordnung-\(UUID().uuidString.prefix(6))"))
    }

    override func tearDown() async throws {
        guard let folder else { return }
        store.selectedNoteID = nil
        try? FileManager.default.removeItem(at: folder)
        store.sidebarSelection = .all
        store.searchText = ""
        store.searchFilter = SearchFilter()
        store.reload()
        store.organization = before
    }

    @discardableResult
    private func note(_ title: String, text: String = "", modified: TimeInterval, pinned: Bool = false, in dir: URL? = nil) throws -> UUID {
        var meta = NoteMetadata(title: title, created: Date(timeIntervalSince1970: 2_000_000 - modified),
                                modified: Date(timeIntervalSince1970: modified), pinned: pinned, searchText: title + "\n" + text)
        meta.kinds = ["text"]
        try NoteFile(meta: meta, body: NoteBody()).write(to: store.uniqueURL(in: dir ?? folder, base: title))
        return meta.id
    }

    private func shown() -> [String] { store.filteredNotes.map(\.meta.title) }

    func testSortModes() throws {
        try note("Birne", modified: 300)
        try note("apfel", modified: 100)
        try note("Zitrone", modified: 200, pinned: true)
        store.reload()
        store.sidebarSelection = .folder(folder)
        XCTAssertEqual(shown(), ["Zitrone", "Birne", "apfel"], "pinned first, then newest")
        store.organization.sortMode = .title
        XCTAssertEqual(shown(), ["Zitrone", "apfel", "Birne"])
        store.organization.sortMode = .created
        XCTAssertEqual(shown(), ["Zitrone", "apfel", "Birne"], "created is the reverse of modified here")
    }

    func testManualOrderSurvivesReloadAndDoesNotTouchNotes() throws {
        let a = try note("A", modified: 300), b = try note("B", modified: 200), c = try note("C", modified: 100)
        store.reload()
        store.sidebarSelection = .folder(folder)
        let dates = store.filteredNotes.map(\.meta.modified)
        store.moveNote(c, before: a)
        XCTAssertEqual(store.organization.sortMode, .manual, "dragging switches to the own order")
        XCTAssertEqual(shown(), ["C", "A", "B"])
        store.stepNote(b, by: -1)
        XCTAssertEqual(shown(), ["C", "B", "A"])
        store.moveNote(c, before: nil)
        XCTAssertEqual(shown(), ["B", "A", "C"])

        try note("Neu", modified: 50)
        store.reload()
        XCTAssertEqual(shown(), ["Neu", "B", "A", "C"], "a new note shows up on top")
        XCTAssertEqual(Set(store.filteredNotes.map(\.meta.modified)).intersection(dates).count, 3, "ordering changes no note")

        guard case .loaded(let saved) = LibraryOrganization.load(from: store.rootURL) else { return XCTFail("not saved") }
        XCTAssertEqual(saved, store.organization)
        store.loadOrganization()
        XCTAssertEqual(shown(), ["Neu", "B", "A", "C"])

        store.sidebarSelection = .all
        XCTAssertNotEqual(store.orderKey(for: .all), store.orderKey(for: .folder(folder)), "each list has its own order")
    }

    func testFolderOrderAndRename() throws {
        let x = try XCTUnwrap(store.createFolder(named: "Xylophon", in: folder))
        let m = try XCTUnwrap(store.createFolder(named: "Mitte", in: folder))
        let a = try XCTUnwrap(store.createFolder(named: "Anfang", in: folder))
        func names() -> [String] { store.siblingFolders(of: x).names }
        XCTAssertEqual(names(), ["Anfang", "Mitte", "Xylophon"])
        XCTAssertTrue(store.moveFolder(x, before: a))
        XCTAssertEqual(names(), ["Xylophon", "Anfang", "Mitte"])
        store.stepFolder(m, by: -1)
        XCTAssertEqual(names(), ["Xylophon", "Mitte", "Anfang"])
        XCTAssertFalse(store.moveFolder(x, before: folder), "folders of different parents are not reordered")
        store.reload()
        XCTAssertEqual(names(), ["Xylophon", "Mitte", "Anfang"])

        let noteID = try note("In Mitte", modified: 10, in: m)
        store.reload()
        store.sidebarSelection = .folder(m)
        store.moveNote(noteID, before: nil)
        store.renameFolder(m, to: "Zentrum")
        let renamed = folder.appendingPathComponent("Zentrum", isDirectory: true)
        XCTAssertEqual(store.siblingFolders(of: renamed).names, ["Xylophon", "Zentrum", "Anfang"], "a renamed folder keeps its place")
        XCTAssertNotNil(store.organization.noteOrder[store.orderKey(for: .folder(renamed))!])
        store.sortFoldersAlphabetically(besides: renamed)
        XCTAssertEqual(store.siblingFolders(of: renamed).names, ["Anfang", "Xylophon", "Zentrum"])
    }

    func testFavoritesAreIndependentOfPins() throws {
        let a = try note("A", modified: 300, pinned: true), b = try note("B", modified: 200), c = try note("C", modified: 100)
        store.reload()
        store.toggleFavorite(c)
        store.toggleFavorite(b)
        XCTAssertFalse(store.isFavorite(a))
        XCTAssertTrue(store.notes.first { $0.id == a }!.meta.pinned)
        XCTAssertFalse(store.notes.first { $0.id == c }!.meta.pinned, "a favorite is not pinned")
        store.sidebarSelection = .favorites
        XCTAssertEqual(shown(), ["C", "B"], "in the order they were added")
        store.moveNote(b, before: c)
        XCTAssertEqual(shown(), ["B", "C"])
        XCTAssertEqual(store.organization.sortMode, .modified, "ordering favorites leaves the other lists alone")
        store.togglePin(b)
        XCTAssertEqual(shown(), ["B", "C"])
        store.toggleFavorite(b)
        XCTAssertEqual(shown(), ["C"])
        XCTAssertEqual(store.favoriteCount, 1)
        XCTAssertEqual(NoteStore.selectionAfterCreatingNote(.favorites), .all)
    }

    func testSmartViews() throws {
        try note("Suppe", text: "rezept #kochen", modified: 300)
        try note("Kuchen", text: "rezept backen", modified: 200)
        try note("Steuer", text: "unterlagen", modified: 100)
        store.reload()
        store.sidebarSelection = .folder(folder)
        XCTAssertNil(store.saveSearchAsSmartView(named: "Leer"), "nothing to save without a search")
        store.searchText = "rezept ordner:\(store.relativeFolderName(folder))"
        XCTAssertNil(store.saveSearchAsSmartView(named: "  "), "a view needs a name")
        let view = try XCTUnwrap(store.saveSearchAsSmartView(named: " Rezepte "))
        XCTAssertEqual(view.name, "Rezepte")
        XCTAssertEqual(store.sidebarSelection, .smartView(view.id))
        XCTAssertFalse(store.isSearching)
        XCTAssertEqual(shown(), ["Suppe", "Kuchen"])
        XCTAssertEqual(store.smartViewCount(view.id), 2)

        try note("Brot", text: "rezept", modified: 400)
        store.reload()
        XCTAssertEqual(shown(), ["Brot", "Suppe", "Kuchen"], "the view follows the library")

        store.searchEverywhere = false
        store.searchText = "kuchen"
        XCTAssertEqual(shown(), ["Kuchen"], "searching inside a view narrows it")
        store.searchText = ""

        store.renameSmartView(view.id, to: "Kochen")
        XCTAssertEqual(store.smartView(view.id)?.name, "Kochen")
        store.editSmartView(view.id)
        XCTAssertEqual(store.searchText, "rezept")
        XCTAssertEqual(store.searchFilter.folder, store.relativeFolderName(folder))
        store.searchText = "unterlagen"
        store.updateSmartView(view.id)
        XCTAssertEqual(shown(), ["Steuer"])

        store.deleteSmartView(view.id)
        XCTAssertEqual(store.sidebarSelection, .all)
        XCTAssertTrue(store.smartViewNotes(view.id, in: store.notes).isEmpty, "a deleted view shows nothing and does not crash")
    }

    func testReorderingInsideASearchKeepsTheOtherNotes() throws {
        // #170
        var ids: [String: UUID] = [:]
        for (i, t) in ["A", "B treffer", "C", "D treffer", "E"].enumerated() { ids[t] = try note(t, modified: Double(1000 - i)) }
        store.reload()
        store.sidebarSelection = .folder(folder)
        store.moveNote(ids["E"]!, before: ids["A"]!)
        XCTAssertEqual(shown(), ["E", "A", "B treffer", "C", "D treffer"])
        store.searchEverywhere = false
        store.searchText = "treffer"
        store.moveNote(ids["D treffer"]!, before: ids["B treffer"]!)
        XCTAssertEqual(shown(), ["D treffer", "B treffer"])
        store.searchText = ""
        XCTAssertEqual(shown(), ["E", "A", "D treffer", "C", "B treffer"])

        store.searchEverywhere = true
        store.searchText = "treffer"
        store.stepNote(ids["B treffer"]!, by: -1)
        store.searchText = ""
        XCTAssertEqual(shown(), ["E", "A", "B treffer", "C", "D treffer"])
        XCTAssertEqual(Set(store.organization.noteOrder[store.orderKey(for: .folder(folder))!] ?? []), Set(ids.values),
                       "only this folder's notes are in its order")
    }

    func testSmartViewRemembersWhereTheSearchRan() throws {
        // #172
        let sub = try XCTUnwrap(store.createFolder(named: "Innen", in: folder))
        try note("Drin", text: "wort #marke", modified: 300, in: sub)
        try note("Draussen", text: "wort", modified: 200)
        store.reload()
        store.searchEverywhere = false
        store.sidebarSelection = .folder(sub)
        store.searchText = "wort"
        XCTAssertEqual(shown(), ["Drin"])
        let view = try XCTUnwrap(store.saveSearchAsSmartView(named: "Innen"))
        XCTAssertEqual(view.filter.folder, store.relativeFolderName(sub))
        XCTAssertEqual(shown(), ["Drin"], "the view shows what the list showed")
        store.deleteSmartView(view.id)

        store.searchEverywhere = true
        store.sidebarSelection = .folder(sub)
        store.searchText = "wort"
        let everywhere = try XCTUnwrap(store.saveSearchAsSmartView(named: "Überall"))
        XCTAssertNil(everywhere.filter.folder)
        XCTAssertEqual(Set(shown()), ["Drin", "Draussen"])
        store.deleteSmartView(everywhere.id)
    }

    func testChangesFromOutsideAreTakenOverNotOverwritten() throws {
        // #175
        let a = try note("A", modified: 300), b = try note("B", modified: 200)
        store.reload()
        store.toggleFavorite(a)
        var theirs = store.organization
        let view = SmartView(name: "Vom anderen Mac", filter: SearchFilter(text: "x"))
        theirs.smartViews.append(view)
        theirs.favorites.append(b)
        try theirs.save(to: store.rootURL)

        // Folio changes something before it noticed the new file: both sides survive.
        store.organization.sortMode = .title
        XCTAssertEqual(store.organization.smartViews.map(\.name), ["Vom anderen Mac"])
        XCTAssertEqual(store.organization.favorites, [a, b])
        XCTAssertEqual(store.organization.sortMode, .title)
        XCTAssertEqual(LibraryOrganization.load(from: store.rootURL), .loaded(store.organization))

        // And without any change here, the regular check picks the file up.
        theirs = store.organization
        theirs.smartViews = []
        theirs.sortMode = .created
        try theirs.save(to: store.rootURL)
        store.sidebarSelection = .smartView(view.id)
        store.checkOrganizationChange()
        XCTAssertEqual(store.organization, theirs)
        XCTAssertEqual(store.sidebarSelection, .all, "a view that is gone is not left selected")

        // An unreadable file from outside is not taken over and not destroyed by the check.
        try Data("{kaputt".utf8).write(to: LibraryOrganization.file(in: store.rootURL))
        store.checkOrganizationChange()
        XCTAssertEqual(store.organization, theirs)
    }

    func testRenamingATagKeepsItsOrder() async throws {
        // #174
        func tagged(_ title: String, _ modified: TimeInterval) throws -> UUID {
            var b = BlockRecord(kind: .text)
            b.rtf = RichTextCodec.rtfData(from: NSAttributedString(string: "\(title) #ordnungalt"))
            var meta = NoteMetadata(title: title, tags: ["ordnungalt"], modified: Date(timeIntervalSince1970: modified), searchText: "\(title) #ordnungalt")
            meta.kinds = ["text"]
            try NoteFile(meta: meta, body: NoteBody(blocks: [b])).write(to: store.uniqueURL(in: folder, base: title))
            return meta.id
        }
        let a = try tagged("TA", 300), b = try tagged("TB", 200)
        store.reload()
        store.sidebarSelection = .tag("ordnungalt")
        store.moveNote(b, before: a)
        XCTAssertEqual(shown(), ["TB", "TA"])
        await store.editTag("ordnungalt", to: "ordnungneu")
        store.tagEdit = nil
        XCTAssertEqual(store.sidebarSelection, .tag("ordnungneu"))
        XCTAssertEqual(store.filteredNotes.map(\.id), [b, a], "the own order survives the rename")
        XCTAssertNil(store.organization.noteOrder["tag:ordnungalt"])
    }

    func testUnreadableOrganizationFileIsReported() throws {
        let url = LibraryOrganization.file(in: store.rootURL)
        try Data("kaputt".utf8).write(to: url)
        store.lastError = nil
        store.loadOrganization()
        XCTAssertEqual(store.organization, LibraryOrganization())
        XCTAssertTrue(store.lastError?.contains("Notizen sind nicht betroffen") == true)
        store.lastError = nil
        for f in try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        where f.lastPathComponent.hasPrefix("organization-defekt-") { try FileManager.default.removeItem(at: f) }
    }
}

/// Printing (#169) and the note information (#19).
@MainActor
final class PrintAndInfoTests: XCTestCase {
    private func doc(paragraphs: Int, code: String? = nil) -> NoteDocument {
        var b = BlockRecord(kind: .text)
        let text = (1...paragraphs).map { "Absatz \($0) mit etwas mehr Text, damit die Seite sich füllt." }.joined(separator: "\n")
        b.rtf = RichTextCodec.rtfData(from: NSAttributedString(string: text, attributes: ThemeManager.shared.bodyAttributes))
        var blocks = [b]
        if let code {
            var c = BlockRecord(kind: .code)
            c.code = code
            blocks.append(c)
        }
        return NoteDocument(file: NoteFile(meta: NoteMetadata(title: "Druck"), body: NoteBody(blocks: blocks)), url: URL(fileURLWithPath: "/dev/null"))
    }

    private func printFolders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("folio-print-") }
    }

    func testLongNotePrintsOnSeveralPagesAndLeavesNoFiles() async throws {
        let before = printFolders()
        let data: Data
        do {
            data = try await NotePDFExporter.pdfData(doc(paragraphs: 200, code: "print(1)\nprint(2)"))
        } catch {
            XCTAssertEqual(printFolders(), before, "no temporary file stays behind after an error either")
            // Build servers may have no print system at all; everywhere else this must work.
            try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "no print system here: \(error.localizedDescription)")
            throw error
        }
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(pdf.pageCount, 2)
        XCTAssertTrue(pdf.string?.contains("Absatz 200") == true)
        XCTAssertTrue(pdf.string?.contains("print(2)") == true)
        XCTAssertEqual(printFolders(), before, "no temporary file stays behind")

        guard let op = try? NotePrinter.operation(for: data, title: "Druck") else {
            try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "no print system here")
            return XCTFail("no print operation")
        }
        XCTAssertTrue(op.showsPrintPanel)
        XCTAssertEqual(op.jobTitle, "Druck")
        XCTAssertTrue(op.printPanel.options.isSuperset(of: [.showsPaperSize, .showsOrientation, .showsPageRange, .showsScaling]))
        XCTAssertEqual(op.printInfo.jobDisposition, .spool)
    }

    func testUnreadablePrintDataIsAnErrorNotACrash() {
        XCTAssertThrowsError(try NotePrinter.operation(for: Data("kein pdf".utf8), title: "x")) {
            XCTAssertEqual($0.localizedDescription, "Die Druckansicht der Notiz konnte nicht erzeugt werden.")
        }
        XCTAssertThrowsError(try NotePrinter.operation(for: Data(), title: ""))
    }

    func testStatisticsOfADocument() {
        let s = doc(paragraphs: 3, code: "a = 1\n\nprint(a)").statistics
        XCTAssertEqual(s.paragraphs, 3)
        XCTAssertEqual(s.words, 3 * 11)
        XCTAssertEqual(s.codeBlocks, 1)
        XCTAssertEqual(s.codeLines, 2)
        XCTAssertFalse(NoteInfoView.date(Date(timeIntervalSince1970: 0)).isEmpty)
    }
}

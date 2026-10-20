import AppKit
import XCTest
@testable import Folio
import FolioCore

/// Titles computed when a note is saved (#96, #97, #95).
@MainActor
final class NoteTitleTests: XCTestCase {
    private func title(_ text: String) -> String {
        var b = BlockRecord(kind: .text)
        b.rtf = RichTextCodec.rtfData(from: NSAttributedString(string: text))
        return NoteDocument(file: NoteFile(meta: NoteMetadata(title: "Alt"), body: NoteBody(blocks: [b])), url: URL(fileURLWithPath: "/dev/null")).makeFile().meta.title
    }

    func testSweepOnlyAllowsKnownLegacyTitleNormalization() {
        XCTAssertTrue(LibrarySweepTest.isLegacyTitleNormalization("Ein langer Titel …", "Ein langer Titel mit weiteren Wörtern"))
        XCTAssertTrue(LibrarySweepTest.isLegacyTitleNormalization("Zwei   Wörter", "Zwei Wörter"))
        XCTAssertFalse(LibrarySweepTest.isLegacyTitleNormalization("Eigener Titel", "Anderer Titel"))
        XCTAssertFalse(LibrarySweepTest.isLegacyTitleNormalization("…", "Beliebig"))
        XCTAssertFalse(LibrarySweepTest.isLegacyTitleNormalization("Alt …", "Neu und anders"))
    }

    func testSweepKeepsWordBoundariesBetweenTextBlocks() {
        let blocks = ["Geschichte", "Großdeutsche Lösung"].map { text in
            var block = BlockRecord(kind: .text)
            block.rtf = RichTextCodec.rtfData(from: NSAttributedString(string: text))
            return block
        }
        let file = NoteFile(meta: NoteMetadata(title: "Geschichte"), body: NoteBody(blocks: blocks))
        XCTAssertEqual(LibrarySweepTest.text(in: file), "Geschichte\nGroßdeutsche Lösung")
        let markdown = MarkdownTransfer.markdown(for: file, filesFolder: "Dateien").0
        let back = MarkdownTransfer.note(fromMarkdown: markdown, title: "Geschichte", baseURL: nil)
        for word in ["geschichte", "großdeutsche", "lösung"] {
            XCTAssertTrue(back.meta.searchText.lowercased().contains(word))
        }
    }

    func testNoteWithoutTextKeepsItsTitle() {
        var image = BlockRecord(kind: .image)
        image.attachmentID = UUID()
        let doc = NoteDocument(file: NoteFile(meta: NoteMetadata(title: "1+1="), body: NoteBody(blocks: [BlockRecord(kind: .text), image])),
                               url: URL(fileURLWithPath: "/dev/null"))
        XCTAssertEqual(doc.makeFile().meta.title, "1+1=")
        XCTAssertEqual(title(""), "Alt", "an empty note keeps its title too")
        XCTAssertEqual(title("Neu"), "Neu", "text still sets the title")
    }

    func testCaptureDateLineIsNoTitle() {
        XCTAssertEqual(title("— 20. Okt. 2026, 19:31 —\nIdee für das Projekt"), "Idee für das Projekt")
        XCTAssertEqual(title("Meine Notiz\n— 20. Okt. 2026, 19:31 —\nNeu"), "Meine Notiz")
        XCTAssertEqual(title("— Gedankenstrich am Anfang ist erlaubt, wenn die Zeile lang genug ist und weitergeht —"), "— Gedankenstrich am Anfang ist erlaubt, wenn die Zeile lang genug ist und weitergeht —")
    }

    func testListMarkersAreNotPartOfTheTitle() {
        XCTAssertEqual(title("•\tJuli 14\n•\tAugust"), "Juli 14")
        XCTAssertEqual(title("1\tTM SMR 125 (2025) 43PS"), "TM SMR 125 (2025) 43PS")
        XCTAssertEqual(title("12. Einkauf"), "Einkauf")
        XCTAssertEqual(title("\t\t☐ offene Aufgabe"), "offene Aufgabe")
        XCTAssertEqual(title("☑ erledigt"), "erledigt")
        XCTAssertEqual(title("F U C K     Y O U"), "F U C K Y O U")
        XCTAssertEqual(title("2s"), "2s", "a number glued to a word is no list marker")
        XCTAssertEqual(title("10 km/h"), "10 km/h", "a number followed by a space is text, not a list")
        XCTAssertEqual(title("•\t10 km/h"), "10 km/h")
    }
}

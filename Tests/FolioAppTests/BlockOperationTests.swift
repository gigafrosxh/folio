import AppKit
import XCTest
@testable import Folio
import FolioCore

/// #57: inserting, moving, deleting and splitting blocks, with edge cases and undo.
@MainActor
final class BlockOperationTests: XCTestCase {
    /// The document only holds its undo manager weakly (it belongs to the window).
    private let undo = UndoManager()

    private func doc(_ text: String = "") -> NoteDocument {
        var b = BlockRecord(kind: .text)
        b.rtf = RichTextCodec.rtfData(from: NSAttributedString(string: text))
        let file = NoteFile(meta: NoteMetadata(title: "Test"), body: NoteBody(blocks: [b]))
        let d = NoteDocument(file: file, url: URL(fileURLWithPath: "/dev/null"))
        undo.removeAllActions()
        undo.groupsByEvent = false
        d.undoManager = undo
        return d
    }

    private func step(_ d: NoteDocument, _ change: () -> Void) {
        d.undoManager?.beginUndoGrouping(); change(); d.undoManager?.endUndoGrouping()
    }

    private func kinds(_ d: NoteDocument) -> [BlockKind] { d.blocks.map(\.kind) }
    private func texts(_ d: NoteDocument) -> [String] { d.blocks.filter { $0.kind == .text }.map(\.storage.string) }

    func testNewDocumentStartsAndEndsWithText() {
        let file = NoteFile(meta: NoteMetadata(), body: NoteBody(blocks: [BlockRecord(kind: .code)]))
        XCTAssertEqual(kinds(NoteDocument(file: file, url: URL(fileURLWithPath: "/dev/null"))), [.text, .code, .text])
        XCTAssertEqual(kinds(NoteDocument(file: NoteFile(meta: NoteMetadata(), body: NoteBody()), url: URL(fileURLWithPath: "/dev/null"))), [.text])
    }

    func testInsertSplitsTextAtCursor() {
        let d = doc("Erste Zeile\nZweite Zeile")
        step(d) { d.insert(BlockModel(kind: .code), after: d.blocks[0].id, splitAt: 12) }
        XCTAssertEqual(kinds(d), [.text, .code, .text])
        XCTAssertEqual(d.blocks[0].storage.string, "Erste Zeile")
        XCTAssertEqual(d.blocks[2].storage.string, "Zweite Zeile")
    }

    func testInsertSplitEdgeCases() {
        // Cursor at the very start: the text moves below the new block.
        let a = doc("Text")
        step(a) { a.insert(BlockModel(kind: .code), after: a.blocks[0].id, splitAt: 0) }
        XCTAssertEqual(a.blocks[0].storage.string, "")
        XCTAssertEqual(a.blocks.first { $0.kind == .text && !$0.storage.string.isEmpty }?.storage.string, "Text")
        // Cursor at the end: nothing is split.
        let b = doc("Text")
        step(b) { b.insert(BlockModel(kind: .code), after: b.blocks[0].id, splitAt: 4) }
        XCTAssertEqual(b.blocks[0].storage.string, "Text")
        XCTAssertEqual(kinds(b), [.text, .code, .text])
        // Cursor right after a line break: no empty line is left behind.
        let c = doc("Eins\n\nZwei")
        step(c) { c.insert(BlockModel(kind: .math), after: c.blocks[0].id, splitAt: 5) }
        XCTAssertEqual(c.blocks[0].storage.string, "Eins")
        XCTAssertTrue(c.blocks.contains { $0.storage.string == "\nZwei" || $0.storage.string == "Zwei" })
        // Emoji and combining characters are not cut apart (UTF-16 positions).
        let e = doc("😀 e\u{301}x")
        step(e) { e.insert(BlockModel(kind: .code), after: e.blocks[0].id, splitAt: 2) }
        XCTAssertEqual(e.blocks[0].storage.string, "😀")
    }

    func testUndoRedoInsertRestoresTextExactly() {
        let d = doc("Hallo Welt")
        let before = d.blocks.map(\.id)
        step(d) { d.insert(BlockModel(kind: .code), after: d.blocks[0].id, splitAt: 5) }
        d.undoManager?.undo()
        XCTAssertEqual(d.blocks.map(\.id), before)
        XCTAssertEqual(d.blocks[0].storage.string, "Hallo Welt")
        d.undoManager?.redo()
        XCTAssertEqual(kinds(d), [.text, .code, .text])
        XCTAssertEqual(d.blocks[0].storage.string, "Hallo")
    }

    func testRemoveMergesNeighbourTextAndUndoes() {
        let d = doc("Oben")
        let code = BlockModel(kind: .code)
        step(d) { d.insert(code, after: d.blocks[0].id) }
        d.blocks[2].storage.setAttributedString(NSAttributedString(string: "Unten"))
        step(d) { d.remove(code.id) }
        XCTAssertEqual(kinds(d), [.text])
        XCTAssertTrue(d.blocks[0].storage.string.contains("Oben") && d.blocks[0].storage.string.contains("Unten"), "neighbouring text joins")
        d.undoManager?.undo()
        XCTAssertTrue(d.blocks.contains { $0 === code })
        XCTAssertEqual(d.blocks[0].storage.string, "Oben")
    }

    func testRemoveLastBlockKeepsATextBlock() {
        let d = doc("x")
        step(d) { d.remove(d.blocks[0].id) }
        XCTAssertFalse(d.blocks.isEmpty)
        XCTAssertEqual(d.blocks.first?.kind, .text)
        step(d) { d.remove(UUID()) }   // unknown id: nothing happens
        XCTAssertFalse(d.blocks.isEmpty)
    }

    func testMoveSkipsEmptyTextAndStaysInBounds() {
        let d = doc("Anfang")
        let a = BlockModel(kind: .code), b = BlockModel(kind: .image)
        step(d) { d.insert(a, after: d.blocks[0].id) }
        step(d) { d.insert(b, after: a.id) }
        let order = d.blocks.map(\.id)
        step(d) { d.move(b.id, by: -1) }
        let ai = d.blocks.firstIndex { $0 === a }!, bi = d.blocks.firstIndex { $0 === b }!
        XCTAssertLessThan(bi, ai, "the image jumped above the code block")
        XCTAssertEqual(d.blocks.first?.kind, .text)
        XCTAssertEqual(d.blocks.last?.kind, .text)
        d.undoManager?.undo()
        XCTAssertEqual(d.blocks.map(\.id), order)
        for _ in 0..<10 { step(d) { d.move(b.id, by: 1) } }
        XCTAssertEqual(d.blocks.last?.kind, .text, "moving past the end keeps a text block last")
        for _ in 0..<10 { step(d) { d.move(b.id, by: -1) } }
        XCTAssertEqual(d.blocks.first?.kind, .text)
    }

    func testBlockSettingChangesUndo() {
        let d = doc()
        let code = BlockModel(kind: .code)
        step(d) { d.insert(code, after: d.blocks[0].id) }
        step(d) { d.changeBlock(code, "Sprache") { code.language = "swift"; code.stdin = "1"; code.outputCollapsed = true } }
        d.undoManager?.undo()
        XCTAssertEqual(code.language, "python")
        XCTAssertNil(code.stdin)
        XCTAssertFalse(code.outputCollapsed)
        d.undoManager?.redo()
        XCTAssertEqual(code.language, "swift")
    }

    func testRecordsRoundTripThroughFile() throws {
        let d = doc("Text mit #tag und Link")
        let code = BlockModel(kind: .code)
        code.storage.setAttributedString(NSAttributedString(string: "print(1)"))
        code.stdin = "eingabe"
        step(d) { d.insert(code, after: d.blocks[0].id) }
        let file = d.makeFile()
        XCTAssertEqual(file.meta.tags, ["tag"])
        XCTAssertEqual(Set(file.meta.kinds ?? []), ["text", "code"])
        let again = NoteDocument(file: try NoteFile.decode(file.encoded()), url: URL(fileURLWithPath: "/dev/null"))
        XCTAssertEqual(again.blocks.map(\.kind), d.blocks.map(\.kind))
        XCTAssertEqual(again.blocks.first { $0.kind == .code }?.stdin, "eingabe")
    }
}

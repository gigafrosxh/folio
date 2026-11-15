import AppKit
import XCTest
@testable import Folio
import FolioCore

/// #37 and #40: tags from suggestions and AI answers as blocks.
@MainActor
final class AIAssistAppTests: XCTestCase {
    private let undo = UndoManager()

    private func doc(_ text: String) -> NoteDocument {
        var b = BlockRecord(kind: .text)
        b.rtf = RichTextCodec.rtfData(from: NSAttributedString(string: text))
        let d = NoteDocument(file: NoteFile(meta: NoteMetadata(title: "Test"), body: NoteBody(blocks: [b])), url: URL(fileURLWithPath: "/dev/null"))
        undo.groupsByEvent = false
        d.undoManager = undo
        return d
    }

    private func step(_ change: () -> Void) { undo.beginUndoGrouping(); change(); undo.endUndoGrouping() }

    func testAppendTagUsesTagLineAndUndoes() {
        let d = doc("Einkauf\nMilch")
        undo.beginUndoGrouping(); d.appendTag("haushalt"); undo.endUndoGrouping()
        XCTAssertEqual(d.blocks[0].storage.string, "Einkauf\nMilch\n#haushalt")
        undo.beginUndoGrouping(); d.appendTag("liste"); undo.endUndoGrouping()
        XCTAssertEqual(d.blocks[0].storage.string, "Einkauf\nMilch\n#haushalt #liste")
        undo.undo()
        XCTAssertEqual(d.blocks[0].storage.string, "Einkauf\nMilch\n#haushalt")
        undo.redo()
        XCTAssertEqual(d.blocks[0].storage.string, "Einkauf\nMilch\n#haushalt #liste")
        let empty = doc("")
        step { empty.appendTag("neu") }
        XCTAssertEqual(empty.blocks[0].storage.string, "#neu")
    }

    func testAnswerBecomesBlocks() {
        let d = doc("Frage")
        let md = "Antwort mit **fett**:\n```swift\nlet a = 1\n```\n| A | B |\n|---|---|\n| 1 | 2 |"
        step { d.insertAnswerBlocks(md, after: d.blocks[0].id, theme: ThemeManager.shared) }
        let kinds = d.blocks.map(\.kind)
        XCTAssertEqual(Array(kinds.prefix(4)), [.text, .text, .code, .text])
        XCTAssertEqual(d.blocks[0].storage.string, "Frage")
        XCTAssertEqual(d.blocks[1].storage.string, "Antwort mit fett:")
        XCTAssertEqual(d.blocks[2].storage.string, "let a = 1")
        XCTAssertEqual(d.blocks[2].language, "swift")
        XCTAssertEqual(d.blocks[3].storage.string, "A\tB\n1\t2")
        let font = d.blocks[3].storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        // Unknown languages fall back to plain text instead of a language Folio can't highlight.
        let e = doc("x")
        step { e.insertAnswerBlocks("```klingonisch\nqapla\n```", after: nil, theme: ThemeManager.shared) }
        XCTAssertEqual(e.blocks.first { $0.kind == .code }?.language, "plain")
        let f = doc("x")
        step { f.insertAnswerBlocks("```py\nprint(1)\n```", after: nil, theme: ThemeManager.shared) }
        XCTAssertEqual(f.blocks.first { $0.kind == .code }?.language, "python")
    }
}

import AppKit
import XCTest
@testable import FolioCore
@testable import Folio

/// Tag changes and template filling without touching any file (#147), and the chat prompt (#140).
@MainActor
final class StoreOperationTests: XCTestCase {
    private func file(_ text: String) -> NoteFile {
        var b = BlockRecord(kind: .text)
        b.rtf = RichTextCodec.rtfData(from: NSAttributedString(string: text))
        return NoteFile(meta: NoteMetadata(title: "T"), body: NoteBody(blocks: [b]))
    }

    private func text(_ f: NoteFile) -> String { RichTextCodec.attributedString(from: f.body.blocks[0].rtf).string }

    func testRenameTag() {
        var f = file("Text #alt und #alt/unter und #altbau")
        XCTAssertTrue(NoteStore.renameTag("alt", to: "neu", in: &f))
        XCTAssertEqual(text(f), "Text #neu und #neu/unter und #altbau")
    }

    func testRemoveTag() {
        var f = file("Text #weg Ende")
        XCTAssertTrue(NoteStore.renameTag("weg", to: nil, in: &f))
        XCTAssertFalse(text(f).contains("#weg"))
    }

    func testUnknownTagChangesNothing() {
        var f = file("Text #da")
        let before = f.body.blocks[0].rtf
        XCTAssertFalse(NoteStore.renameTag("fehlt", to: "x", in: &f))
        XCTAssertEqual(f.body.blocks[0].rtf, before)
    }

    func testFillTemplateGivesNewIdsAndFindsCursor() throws {
        var f = file("{{titel}}\nVor {{cursor}}Nach")
        var code = BlockRecord(kind: .code)
        code.code = "# {{titel}}"
        f.body.blocks.append(code)
        f.meta.pinned = true
        let oldIDs = f.body.blocks.map(\.id), oldID = f.meta.id
        let context = TemplateVariables.Context(date: Date(), title: "Name")
        let cursor = try XCTUnwrap(NoteStore.fillTemplate(&f, title: "Name", context: context))
        XCTAssertEqual(text(f), "Name\nVor Nach")
        XCTAssertEqual(f.body.blocks[1].code, "# Name")
        XCTAssertEqual(cursor.block, f.body.blocks[0].id)
        XCTAssertEqual(cursor.offset, ("Name\nVor " as NSString).length)
        XCTAssertNotEqual(f.meta.id, oldID)
        XCTAssertTrue(Set(oldIDs).isDisjoint(with: f.body.blocks.map(\.id)))
        XCTAssertEqual(f.meta.title, "Name")
        XCTAssertFalse(f.meta.pinned)
    }

    private func plan(_ passages: [Passage]) -> ContextPlan { ContextPlan(passages: passages, omitted: 0, usedTokens: 0, budget: 0) }

    func testPromptWithoutSources() {
        let prompt = AIChatModel.prompt(question: "Was?", plan: plan([]), history: "", selection: nil)
        XCTAssertEqual(prompt, "Es wurden keine passenden Stellen in den Notizen gefunden.\n\nFrage: Was?")
    }

    func testPromptWithEverythingAndLongSelection() {
        let passage = Passage(noteID: UUID(), noteTitle: "N", index: 0, text: "Stelle")
        let prompt = AIChatModel.prompt(question: "Was?", plan: plan([passage]), history: "Vorher", selection: String(repeating: "x", count: 3000))
        XCTAssertTrue(prompt.hasPrefix("Bisheriges Gespräch:\nVorher\n\nQuellen:\n"), prompt)
        XCTAssertTrue(prompt.contains(String(repeating: "x", count: 2400) + "\n\"\"\""))
        XCTAssertFalse(prompt.contains(String(repeating: "x", count: 2401)))
        XCTAssertTrue(prompt.hasSuffix("Frage: Was?"))
    }
}

/// Release notes in the update window (#151).
final class MarkdownViewBlockTests: XCTestCase {
    func testBlocks() {
        let blocks = MarkdownView.blocks(of: "# Titel\nText eins\nzwei\n\n- a\n  - b\n2) c\n> Zitat\n---\n```\nx  y\n```\n```\noffen")
        XCTAssertEqual(blocks, [.heading(1, "Titel"), .paragraph("Text eins zwei"), .bullet(0, "a"), .bullet(1, "b"), .numbered("2)", "c"),
                                .quote("Zitat"), .rule, .code("x  y"), .code("offen")])
    }
}

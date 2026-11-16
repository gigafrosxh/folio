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

    func testWideTablesBecomeOneLinePerRow() {
        let long = String(repeating: "lange Beschreibung ", count: 6)
        let wide = NoteDocument.table(header: ["Beschreibung", "Preis"], rows: [[long, "9 EUR"], ["Kurz", "3 EUR"]], theme: ThemeManager.shared)
        XCTAssertEqual(wide.string, "Beschreibung: \(long) · Preis: 9 EUR\nBeschreibung: Kurz · Preis: 3 EUR")
        let small = NoteDocument.table(header: ["A", "B"], rows: [["1", "2"]], theme: ThemeManager.shared)
        XCTAssertEqual(small.string, "A\tB\n1\t2")
        let headerOnly = NoteDocument.table(header: [long, "x"], rows: [], theme: ThemeManager.shared)
        XCTAssertEqual(headerOnly.string, long + "\tx")
    }

    func testReplacementKeepsStyleWithoutAsterisks() {
        var base = ThemeManager.shared.bodyAttributes
        base[.foregroundColor] = NSColor.systemRed
        let out = ChatAnswerFormatter.attributed(fromMarkdown: "Ein **wichtiger** Satz", theme: ThemeManager.shared, base: base)
        XCTAssertEqual(out.string, "Ein wichtiger Satz")
        XCTAssertEqual(out.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemRed)
        let font = out.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    func testItalicStrikeAndSnakeCase() {
        let out = ChatAnswerFormatter.attributed(fromMarkdown: "*Kursiv* und _anders_, ~~weg~~, snake_case_name und 2 * 3 * 4", theme: ThemeManager.shared)
        XCTAssertEqual(out.string, "Kursiv und anders, weg, snake_case_name und 2 * 3 * 4")
        func italic(_ i: Int) -> Bool { (out.attribute(.font, at: i, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true }
        XCTAssertTrue(italic(0))
        XCTAssertTrue(italic(11))
        XCTAssertFalse(italic(30))
        XCTAssertNotNil(out.attribute(.strikethroughStyle, at: 19, effectiveRange: nil))
    }

    func testHeadingKeepsReplacedStyle() {
        var base = TextStyle.title.attributes(theme: ThemeManager.shared)
        base[.foregroundColor] = NSColor.systemRed
        let out = ChatAnswerFormatter.attributed(fromMarkdown: "# Neue Überschrift", theme: ThemeManager.shared, base: base)
        XCTAssertEqual(out.string, "Neue Überschrift")
        XCTAssertEqual((out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, (base[.font] as? NSFont)?.pointSize)
        XCTAssertEqual(out.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemRed)
        // Inserting from the chat keeps the heading style.
        let chat = ChatAnswerFormatter.attributed(fromMarkdown: "# Neu", theme: ThemeManager.shared)
        XCTAssertEqual((chat.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize,
                       (TextStyle.subheading.attributes(theme: ThemeManager.shared)[.font] as? NSFont)?.pointSize)
    }

    func testNestedBoldInItalics() {
        let out = ChatAnswerFormatter.attributed(fromMarkdown: "*ein **wichtiger** Satz*", theme: ThemeManager.shared)
        XCTAssertEqual(out.string, "ein wichtiger Satz")
        let traits = (out.attribute(.font, at: 5, effectiveRange: nil) as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
        XCTAssertTrue(traits.contains(.boldFontMask) && traits.contains(.italicFontMask))
        // Code stays literal.
        XCTAssertEqual(ChatAnswerFormatter.attributed(fromMarkdown: "`a *b* c`", theme: ThemeManager.shared).string, "a *b* c")
    }

    func testOllamaDownMeansFallback() async {
        let theme = ThemeManager.shared
        let saved = theme.settings
        defer { theme.settings = saved }
        theme.settings.aiProvider = "ollama"
        theme.settings.ollamaURL = "http://127.0.0.1:9"
        theme.settings.ollamaModel = "x"
        await OllamaStatus.shared.refresh()
        let a = AIAvailability.current
        XCTAssertFalse(a.isAvailable)
        XCTAssertEqual(a.title, "Ollama antwortet nicht")
        XCTAssertTrue(a.explanation.contains("passende Stellen"))
        theme.settings.aiProvider = "apple"
        if case .ollamaDown = AIAvailability.current.state { XCTFail("Apple Intelligence darf den Ollama-Status nicht zeigen") }
    }

    func testBoldItalicWithSharedEnds() {
        func traits(_ s: NSAttributedString, _ i: Int) -> NSFontTraitMask {
            (s.attribute(.font, at: i, effectiveRange: nil) as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
        }
        let a = ChatAnswerFormatter.attributed(fromMarkdown: "***wichtig***", theme: ThemeManager.shared)
        XCTAssertEqual(a.string, "wichtig")
        XCTAssertTrue(traits(a, 0).contains([.boldFontMask, .italicFontMask]))
        let b = ChatAnswerFormatter.attributed(fromMarkdown: "**fett und *kursiv***", theme: ThemeManager.shared)
        XCTAssertEqual(b.string, "fett und kursiv")
        XCTAssertTrue(traits(b, 0).contains(.boldFontMask) && !traits(b, 0).contains(.italicFontMask))
        XCTAssertTrue(traits(b, 10).contains([.boldFontMask, .italicFontMask]))
        // Plain bold followed by text still works.
        XCTAssertEqual(ChatAnswerFormatter.attributed(fromMarkdown: "**a** und **b**", theme: ThemeManager.shared).string, "a und b")
    }

    func testItalicAroundBoldAtTheEnd() {
        let out = ChatAnswerFormatter.attributed(fromMarkdown: "*a **b***", theme: ThemeManager.shared)
        XCTAssertEqual(out.string, "a b")
        let t0 = (out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
        let t2 = (out.attribute(.font, at: 2, effectiveRange: nil) as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
        XCTAssertTrue(t0.contains(.italicFontMask) && !t0.contains(.boldFontMask))
        XCTAssertTrue(t2.contains([.italicFontMask, .boldFontMask]))
        XCTAssertEqual(ChatAnswerFormatter.attributed(fromMarkdown: "\\*kein\\* Kursiv", theme: ThemeManager.shared).string, "*kein* Kursiv")
    }
}

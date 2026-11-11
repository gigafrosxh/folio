import AppKit
import XCTest
import FolioCore
@testable import Folio

/// Pins what Markdown import and export produce for every supported construct (#146).
@MainActor
final class MarkdownRoundtripTests: XCTestCase {
    private func roundtrip(_ markdown: String) -> String {
        MarkdownTransfer.markdown(from: MarkdownTransfer.attributed(fromMarkdown: markdown))
    }

    func testBlockSyntaxSurvives() {
        for line in ["# Titel", "## Abschnitt", "### Unterabschnitt", "- Punkt", "- [ ] Offen", "- [x] Fertig", "1. Eins", "  - Tief", "    - [ ] Tiefer"] {
            XCTAssertEqual(roundtrip(line), line)
        }
    }

    func testInlineSyntaxSurvives() {
        for line in ["Ein **fettes** Wort", "Ein *kursives* Wort", "Ein ~~gestrichenes~~ Wort", "Ein `code` Wort", "[Link](https://example.com/a?b=1)"] {
            XCTAssertEqual(roundtrip(line), line)
        }
    }

    func testVariantsAreNormalized() {
        XCTAssertEqual(roundtrip("* Punkt"), "- Punkt")
        XCTAssertEqual(roundtrip("+ [X] Fertig"), "- [x] Fertig")
        XCTAssertEqual(roundtrip("2) Zwei"), "2. Zwei")
        XCTAssertEqual(roundtrip("__fett__"), "**fett**")
        XCTAssertEqual(roundtrip("_kursiv_"), "*kursiv*")
        XCTAssertEqual(roundtrip("#### Tief"), "### Tief")
        XCTAssertEqual(roundtrip("***"), "---")
    }

    func testEscapesAndUnicode() {
        XCTAssertEqual(MarkdownTransfer.attributed(fromMarkdown: #"a\*b\_c"#).string, "a*b_c")
        XCTAssertEqual(roundtrip(#"a\*b\_c"#), #"a\*b\_c"#)
        XCTAssertEqual(roundtrip("Größe 😀 ñ 日本語"), "Größe 😀 ñ 日本語")
    }

    func testSeveralLinesKeepTheirOrder() {
        let text = "# Titel\n\nText mit **fett**\n- Eins\n- Zwei\n\n1. Erstens"
        XCTAssertEqual(roundtrip(text), text)
    }

    func testQuoteLosesItsMarkerButKeepsItsStyle() {
        let quote = MarkdownTransfer.attributed(fromMarkdown: "> Zitat")
        XCTAssertEqual(quote.string, "Zitat")
        let expected = TextStyle.quote.attributes(theme: ThemeManager.shared)[.font] as? NSFont
        XCTAssertEqual(quote.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, expected)
    }

    func testEveryBlockKindIsExported() {
        let image = FolioArchive.Attachment(filename: "Bild.png", typeIdentifier: "public.png", data: Data([1]))
        let drawing = FolioArchive.Attachment(filename: "Skizze.data", typeIdentifier: "public.data", data: Data([2]))
        let pdf = FolioArchive.Attachment(filename: "Bild.png", typeIdentifier: "com.adobe.pdf", data: Data([3]))
        let audio = FolioArchive.Attachment(filename: "Ton.m4a", typeIdentifier: "public.audio", data: Data([4]))
        func block(_ kind: BlockKind, _ edit: (inout BlockRecord) -> Void) -> BlockRecord {
            var b = BlockRecord(kind: kind)
            edit(&b)
            return b
        }
        let blocks = [
            block(.text) { $0.rtf = RichTextCodec.rtfData(from: MarkdownTransfer.attributed(fromMarkdown: "Text")) },
            block(.text) { $0.rtf = RichTextCodec.rtfData(from: NSAttributedString(string: "  \n")) },
            block(.embed) { $0.code = "Andere" },
            block(.code) { $0.language = "python"; $0.code = "print(1)"; $0.output = "1" },
            block(.database) { $0.code = "select 1" },
            block(.math) { $0.code = "x^2" },
            block(.diagram) { $0.code = "graph TD" },
            block(.image) { $0.attachmentID = image.id; $0.caption = "Alt" },
            block(.drawing) { $0.attachmentID = drawing.id },
            block(.pdf) { $0.attachmentID = pdf.id },
            block(.file) { $0.attachmentID = UUID() },
            block(.audio) { $0.attachmentID = audio.id; $0.output = "Zeile 1\nZeile 2" },
            block(.web) { $0.url = "https://a.example"; $0.caption = "A" },
            block(.web) { $0.url = "https://b.example" },
            block(.web) { _ in },
        ]
        let file = NoteFile(meta: NoteMetadata(title: "T"), body: NoteBody(blocks: blocks), attachments: [image, drawing, pdf, audio])
        let (markdown, files) = MarkdownTransfer.markdown(for: file, filesFolder: "T Dateien")
        let prefix = String(pdf.id.uuidString.prefix(6))
        XCTAssertEqual(markdown, [
            "Text", "![[Andere]]", "```python\nprint(1)\n```", "```text\n1\n```", "```sql\nselect 1\n```", "$$\nx^2\n$$",
            "```mermaid\ngraph TD\n```", "![Alt](T%20Dateien/Bild.png)", "[Zeichnung](T%20Dateien/Skizze.data)",
            "[\(prefix)-Bild.png](T%20Dateien/\(prefix)-Bild.png)", "[Ton.m4a](T%20Dateien/Ton.m4a)", "> Zeile 1\n> Zeile 2",
            "[A](https://a.example)", "[https://b.example](https://b.example)",
        ].joined(separator: "\n\n") + "\n")
        XCTAssertEqual(files.map(\.0), ["Bild.png", "Skizze.data", "\(prefix)-Bild.png", "Ton.m4a"])
    }

    func testImportCreatesTheRightBlocks() {
        let note = MarkdownTransfer.note(fromMarkdown: "# T\n\n```python\nprint(1)\n```\n\n```mermaid\ngraph TD\n```\n\n$$\nx\n$$\n\n![a](https://e.example/b.png)\n\n![a](fehlt.png)\n",
                                         title: "Datei", baseURL: nil)
        XCTAssertEqual(note.meta.title, "T")
        let kinds = note.body.blocks.map(\.kind)
        XCTAssertTrue(kinds.contains(.code) && kinds.contains(.diagram) && kinds.contains(.math) && kinds.contains(.web), "\(kinds)")
        let missing = note.body.blocks.filter { $0.kind == .text }.map { RichTextCodec.attributedString(from: $0.rtf).string }
        XCTAssertTrue(missing.contains("[Bild fehlt: fehlt.png]"), "\(missing)")
    }

    func testImportedColorsAndFontsAreNormalized() {
        let body = NSFont.systemFont(ofSize: 14)
        let s = NSMutableAttributedString(string: "a", attributes: [.foregroundColor: NSColor(srgbRed: 0.01, green: 0.01, blue: 0.01, alpha: 1),
                                                                    .backgroundColor: NSColor.white, .font: NSFont(name: "Times New Roman", size: 12)!])
        s.append(NSAttributedString(string: "b", attributes: [.foregroundColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                                                              .font: NSFont(name: "Menlo", size: 20)!]))
        RichTextCodec.normalizeImported(s, bodyFont: body)
        XCTAssertEqual(s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, NSColor.textColor)
        XCTAssertNil(s.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        XCTAssertEqual((s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 14)
        XCTAssertEqual((s.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)?.fontName, "Menlo-Regular")
        XCTAssertEqual((s.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor)?.redComponent, 1)
    }
}

/// Chat answers pasted into a note (#143).
@MainActor
final class ChatAnswerFormatterTests: XCTestCase {
    private var theme: ThemeManager { ThemeManager.shared }

    func testListsNestingAndNumbers() {
        let s = ChatAnswerFormatter.attributed(fromMarkdown: "- a\n  - b\n- [ ] c\n- [x] d\n3. e", theme: theme)
        XCTAssertEqual(s.string, "• a\n\t• b\n☐ c\n☑ d\n3. e")
    }

    func testHeadingBecomesSubheading() {
        let s = ChatAnswerFormatter.attributed(fromMarkdown: "# Titel", theme: theme)
        XCTAssertEqual(s.string, "Titel")
        XCTAssertEqual(s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, TextStyle.subheading.attributes(theme: theme)[.font] as? NSFont)
    }

    func testBoldAndCodeBecomeFormatting() {
        let s = ChatAnswerFormatter.attributed(fromMarkdown: "x **y** `z` *k*", theme: theme)
        XCTAssertEqual(s.string, "x y z *k*")
        let bold = s.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: bold!).contains(.boldFontMask))
        XCTAssertEqual((s.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)?.isFixedPitch, true)
    }
}

/// Bullets as Apple Notes writes them, with a tab (#167).
@MainActor
final class AppleBulletMarkdownTests: XCTestCase {
    func testTabBulletsBecomeMarkdownLists() {
        let text = NSAttributedString(string: "•\tEins\n\t•\tZwei", attributes: ThemeManager.shared.bodyAttributes)
        XCTAssertEqual(MarkdownTransfer.markdown(from: text), "- Eins\n  - Zwei")
    }

    func testTabBulletsInMarkdownBecomeFolioLists() {
        XCTAssertEqual(MarkdownTransfer.attributed(fromMarkdown: "  •\tEins\n•  Zwei").string, "\t• Eins\n• Zwei")
    }
}

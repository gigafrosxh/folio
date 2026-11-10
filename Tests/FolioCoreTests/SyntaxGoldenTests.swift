import XCTest
@testable import FolioCore

/// Syntax tokens and indentation for several languages, compared with a stored result (#149).
/// FOLIO_WRITE_GOLDEN=1 rewrites the stored file.
final class SyntaxGoldenTests: XCTestCase {
    private let samples: [(String, String)] = [
        ("python", "import os\n# Kommentar \"x\"\ndef f(a, b=1):\n    s = 'text # kein Kommentar'\n    return Foo(a) + 0x1F\n@decorator\nclass Bar: pass\n\"\"\"lang\nblock\"\"\"\n"),
        ("javascript", "const a = `x ${y}`; // Kommentar\nfunction f(b) { return b * 2.5e3; }\n/* block\nende */ let s = \"str\\\"ing\";\n"),
        ("swift", "import Foundation\n@MainActor struct A { let x: Int = 1_000 }\nfunc g() -> String { \"ä😀\" } // c\n"),
        ("sql", "SELECT name, COUNT(*) FROM t -- Kommentar\nwhere id = 'x''y';\n"),
        ("bash", "#!/bin/bash\necho \"$HOME\" # c\nfor i in 1 2; do ls -la; done\n"),
        ("plain", "nichts (hervorheben) 123\n"),
        ("markdown", "# Titel\n**fett** `code`\n"),
    ]

    private var goldenURL: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/syntax-tokens.txt") }

    private func dump() -> String {
        samples.map { id, code in
            let tokens = SyntaxHighlighter.tokens(in: code, language: Languages.spec(for: id)).map { "\($0.kind) \($0.range.location) \($0.range.length)" }
            return "== \(id)\n" + tokens.joined(separator: "\n")
        }.joined(separator: "\n") + "\n"
    }

    func testTokensMatchStoredResult() throws {
        if ProcessInfo.processInfo.environment["FOLIO_WRITE_GOLDEN"] != nil { try dump().write(to: goldenURL, atomically: true, encoding: .utf8) }
        XCTAssertEqual(dump(), try String(contentsOf: goldenURL, encoding: .utf8))
    }

    func testReindentBrackets() {
        XCTAssertEqual(CodeStyle.reindent(code: "func f() {\nif x {\ny()   \n}\n}", language: "swift"), "func f() {\n    if x {\n        y()\n    }\n}")
        XCTAssertEqual(CodeStyle.reindent(code: "a = [\n1,\n\n]", language: "javascript"), "a = [\n  1,\n\n]")
    }

    func testReindentIgnoresBracketsInStringsAndComments() {
        XCTAssertEqual(CodeStyle.reindent(code: "s = \"{\";\nx\n// {\ny", language: "swift"), "s = \"{\";\nx\n// {\ny")
    }

    func testReindentCountsBracketsAfterADivision() {
        XCTAssertEqual(CodeStyle.reindent(code: "a = b / (\nc\n)", language: "swift"), "a = b / (\n    c\n)")
    }

    func testIndentationLanguagesKeepTheirStructure() {
        XCTAssertEqual(CodeStyle.reindent(code: "def f():  \n\tif x:\n\t\ty()", language: "python"), "def f():\n    if x:\n        y()")
    }
}

/// Splitting note text into passages for the AI context (#140).
final class PassageSplitTests: XCTestCase {
    private func split(_ text: String, target: Int = 100) -> [String] {
        Passages.split(noteID: UUID(), title: "T", text: text, target: target).map(\.text)
    }

    func testEmptyTextHasNoPassages() {
        XCTAssertEqual(split(""), [])
        XCTAssertEqual(split(" \n\n  "), [])
    }

    func testShortTextStaysTogether() {
        XCTAssertEqual(split("a\nb"), ["a\nb"])
    }

    func testBlankLineSplitsOnlyLongEnoughText() {
        let long = String(repeating: "x", count: 40)
        XCTAssertEqual(split("kurz\n\nnoch"), ["kurz\nnoch"])
        XCTAssertEqual(split("\(long)\n\nnoch"), [long, "noch"])
    }

    func testHeadingStartsNewPassageAfterEnoughText() {
        let long = String(repeating: "y", count: 90)
        XCTAssertEqual(split("\(long)\n# Titel\nText", target: 200), [long, "# Titel\nText"])
    }

    func testOverlongLineIsCutAtSentenceEnd() {
        let line = String(repeating: "a", count: 60) + ". " + String(repeating: "b", count: 80)
        let parts = split(line)
        XCTAssertEqual(parts.first, String(repeating: "a", count: 60) + ".")
        XCTAssertEqual(parts.last, String(repeating: "b", count: 80))
    }

    func testLineWithoutSentenceEndIsCutAtTarget() {
        XCTAssertEqual(split(String(repeating: "c", count: 250)).map(\.count), [100, 100, 50])
    }

    func testPassagesAreNumbered() {
        let long = String(repeating: "z", count: 40)
        let passages = Passages.split(noteID: UUID(), title: "T", text: "\(long)\n\n\(long)", target: 100)
        XCTAssertEqual(passages.map(\.index), [0, 1])
    }
}

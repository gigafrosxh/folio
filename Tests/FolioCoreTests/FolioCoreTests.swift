import XCTest
@testable import FolioCore

final class FolioArchiveTests: XCTestCase {
    func testRoundTripWithAttachments() throws {
        var block = BlockRecord(kind: .code)
        block.code = "print('hallo')"
        block.language = "python"
        let pdf = FolioArchive.Attachment(filename: "a.pdf", typeIdentifier: "com.adobe.pdf", data: Data(repeating: 7, count: 50_000))
        let meta = NoteMetadata(title: "Titel", tags: ["arbeit"], searchText: "Titel #arbeit")
        let file = NoteFile(meta: meta, body: NoteBody(blocks: [block]), attachments: [pdf])

        let data = try file.encoded()
        XCTAssertEqual(Array(data.prefix(4)), Array("FOLI".utf8))
        XCTAssertLessThan(data.count, 10_000, "repetitive content should compress")

        let decoded = try NoteFile.decode(data)
        XCTAssertEqual(decoded.meta, meta)
        XCTAssertEqual(decoded.body.blocks.first?.code, "print('hallo')")
        XCTAssertEqual(decoded.attachments.first?.data, pdf.data)
        XCTAssertEqual(decoded.attachments.first?.header.filename, "a.pdf")
    }

    func testMetaOnlyReadAndCorruption() throws {
        let file = NoteFile(meta: NoteMetadata(title: "Nur Meta"), body: NoteBody())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".folio")
        try file.write(to: url)
        XCTAssertEqual(try NoteFile.readMetadata(at: url).title, "Nur Meta")

        var data = try Data(contentsOf: url)
        data[data.count - 6] ^= 0xFF
        XCTAssertThrowsError(try NoteFile.decode(data))
        XCTAssertThrowsError(try NoteFile.decode(Data("nope".utf8)))
    }
}

final class TagParserTests: XCTestCase {
    func testTags() {
        let text = "Meeting #Arbeit und #projekt/folio, aber nicht C# oder a#b oder #123 oder https://x.de/#anker. #arbeit"
        XCTAssertEqual(TagParser.tags(in: text), ["arbeit", "projekt/folio"])
    }

    func testUmlauts() {
        XCTAssertEqual(TagParser.tags(in: "#Übung #straße-2"), ["übung", "straße-2"])
    }
}

final class SyntaxHighlighterTests: XCTestCase {
    private func kinds(_ code: String, _ lang: String) -> [String: TokenKind] {
        var map: [String: TokenKind] = [:]
        let ns = code as NSString
        for t in SyntaxHighlighter.tokens(in: code, language: Languages.spec(for: lang)) { map[ns.substring(with: t.range)] = t.kind }
        return map
    }

    func testPythonStringsAndComments() {
        let k = kinds("def f(x):\n    return \"# kein kommentar\"  # echter kommentar\n", "python")
        XCTAssertEqual(k["def"], .keyword)
        XCTAssertEqual(k["\"# kein kommentar\""], .string)
        XCTAssertEqual(k["# echter kommentar"], .comment)
        XCTAssertEqual(k["f"], .function)
    }

    func testSwift() {
        let k = kinds("let s: String = \"a // b\" // c\nfunc go() {}", "swift")
        XCTAssertEqual(k["let"], .keyword)
        XCTAssertEqual(k["String"], .type)
        XCTAssertEqual(k["\"a // b\""], .string)
        XCTAssertEqual(k["// c"], .comment)
    }

    func testAliases() {
        XCTAssertEqual(Languages.spec(for: "py").id, "python")
        XCTAssertEqual(Languages.spec(for: "unbekannt").id, "plain")
    }
}

final class CodeRunnerTests: XCTestCase {
    func testRunsShell() async throws {
        let result = try await CodeRun().run(code: "echo hallo; echo fehler 1>&2; exit 3", language: Languages.spec(for: "bash"))
        XCTAssertEqual(result.stdout, "hallo\n")
        XCTAssertEqual(result.stderr, "fehler\n")
        XCTAssertEqual(result.exitCode, 3)
    }

    func testTimeout() async throws {
        let result = try await CodeRun().run(code: "sleep 5", language: Languages.spec(for: "bash"), timeout: 0.5)
        XCTAssertTrue(result.timedOut)
    }

    func testPythonIfInstalled() async throws {
        guard InterpreterLocator.shared.find("python3") != nil else { throw XCTSkip("kein python3") }
        let result = try await CodeRun().run(code: "print(6*7)", language: Languages.spec(for: "python"))
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "42")
    }

    func testMissingInterpreter() {
        XCTAssertThrowsError(try CodeRun.plan(for: Languages.spec(for: "python"), override: "does-not-exist-xyz {file}"))
    }
}

final class ServerDetectorTests: XCTestCase {
    func testURLFromOutput() {
        XCTAssertEqual(ServerDetector.url(inOutput: " * Running on http://127.0.0.1:5000")?.absoluteString, "http://127.0.0.1:5000")
        XCTAssertEqual(ServerDetector.url(inOutput: "Serving HTTP on 0.0.0.0 port 8000 (http://0.0.0.0:8000/) ...")?.absoluteString, "http://localhost:8000")
        XCTAssertEqual(ServerDetector.url(inOutput: "Server listening on port 3000")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(ServerDetector.url(inOutput: "  ➜  Local:   http://localhost:5173/")?.absoluteString, "http://localhost:5173")
        XCTAssertNil(ServerDetector.url(inOutput: "Result: 12:30 and 3.14"))
    }

    func testSilentServerKeepsRunningPastTimeout() async throws {
        guard InterpreterLocator.shared.find("python3") != nil else { throw XCTSkip("kein python3") }
        let run = CodeRun()
        let detected = expectation(description: "server")
        let code = "import http.server, socketserver\nsocketserver.TCPServer(('127.0.0.1', 0), http.server.SimpleHTTPRequestHandler).serve_forever()"
        let task = Task { try await run.run(code: code, language: Languages.spec(for: "python"), timeout: 2, onServer: { _ in detected.fulfill() }) }
        await fulfillment(of: [detected], timeout: 10)
        try await Task.sleep(for: .seconds(3)) // past the 2 s timeout
        XCTAssertNotNil(run.serverURL)
        run.cancel()
        let result = try await task.value
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.cancelled)
    }
}

final class CodeStyleTests: XCTestCase {
    func testReindentBraces() {
        let input = "func a() {\nif x {\nprint(1)   \n}\n}"
        XCTAssertEqual(CodeStyle.reindent(code: input, language: "swift"), "func a() {\n    if x {\n        print(1)\n    }\n}")
        XCTAssertEqual(CodeStyle.reindent(code: "function f() {\nreturn \"{\";\n}", language: "javascript"), "function f() {\n  return \"{\";\n}")
    }

    func testPythonTabsBecomeSpaces() {
        XCTAssertEqual(CodeStyle.reindent(code: "def f():\n\treturn 1  ", language: "python"), "def f():\n    return 1")
    }

    func testFencesAndReindent() {
        XCTAssertEqual(CodeStyle.stripFences("```python\nx = 1\n```\n"), "x = 1")
        XCTAssertEqual(CodeStyle.reindent("a\n  b\n    c", baseIndent: "\t"), "a\n\t  b\n\t    c")
        XCTAssertEqual(CodeStyle.relativeToFirstLine("    else:\n        return 1"), "else:\n    return 1")
    }

    func testGofmtIfInstalled() throws {
        guard CodeFormatter.available(for: Languages.spec(for: "go")) != nil else { throw XCTSkip("kein gofmt") }
        let out = try CodeFormatter.format("package main\nfunc main(){\nx:=1\n_=x}", language: Languages.spec(for: "go"))
        XCTAssertTrue(out.contains("\tx := 1"))
    }
}

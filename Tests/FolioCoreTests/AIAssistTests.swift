import XCTest
@testable import FolioCore

final class AIAssistTests: XCTestCase {
    // MARK: AnswerBlocks (#40)

    func testAnswerWithCodeAndTable() {
        let md = """
        Hier ist die Lösung:

        ```Python
        print("hi")
        x = 1
        ```

        | Name | Wert |
        |------|-----:|
        | a | 1 |
        | b \\| c |
        Ende.
        """
        let s = AnswerBlocks.segments(of: md)
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s[0], .text("Hier ist die Lösung:"))
        XCTAssertEqual(s[1], .code(language: "python", code: "print(\"hi\")\nx = 1"))
        XCTAssertEqual(s[2], .table(header: ["Name", "Wert"], rows: [["a", "1"], ["b | c", ""]]))
        XCTAssertEqual(s[3], .text("Ende."))
    }

    func testPlainAnswerAndUnclosedFence() {
        XCTAssertEqual(AnswerBlocks.segments(of: "- eins\n- **zwei**"), [.text("- eins\n- **zwei**")])
        XCTAssertEqual(AnswerBlocks.segments(of: "```\nlet a = 1"), [.code(language: "text", code: "let a = 1")])
        XCTAssertEqual(AnswerBlocks.segments(of: "  \n\n"), [])
        // A pipe line without a separator row stays text.
        XCTAssertEqual(AnswerBlocks.segments(of: "| nur | eine Zeile |"), [.text("| nur | eine Zeile |")])
    }

    // MARK: Text actions (#36)

    func testTextActions() {
        XCTAssertEqual(AITextAction.allCases.count, 4)
        XCTAssertTrue(AITextAction.rewrite.replacesSelection)
        XCTAssertTrue(AITextAction.simplify.replacesSelection)
        XCTAssertFalse(AITextAction.explain.replacesSelection)
        XCTAssertFalse(AITextAction.quiz.replacesSelection)
        for a in AITextAction.allCases { XCTAssertFalse(a.label.isEmpty); XCTAssertFalse(a.instructions.isEmpty) }
        XCTAssertTrue(AITextAction.explain.prompt(for: "Photosynthese").contains("Photosynthese"))
        let long = String(repeating: "x", count: 100)
        let p = AITextAction.rewrite.prompt(for: long, limit: 10)
        XCTAssertTrue(p.contains("[…]"))
        XCTAssertFalse(p.contains(String(repeating: "x", count: 11)))
    }

    // MARK: Tag suggestions (#37)

    func testLibraryTagsComeFirst() {
        let text = "Heute am Projekt Folio gearbeitet. Das Rezept für Pasta liegt woanders."
        let lib: [(tag: String, count: Int)] = [("rezepte", 3), ("projekt/folio", 9), ("urlaub", 5), ("ab", 50)]
        let out = TagSuggester.suggest(text: text, existing: [], libraryTags: lib)
        XCTAssertEqual(Array(out.prefix(1)), ["projekt/folio"])
        XCTAssertFalse(out.contains("urlaub"))
        XCTAssertFalse(out.contains("ab"), "zu kurze Tags werden nicht vorgeschlagen")
        XCTAssertFalse(TagSuggester.suggest(text: text, existing: ["projekt/folio"], libraryTags: lib).contains("projekt/folio"))
    }

    func testFrequentNouns() {
        let text = "Die Waschmaschine ist kaputt. Morgen kommt der Techniker für die Waschmaschine. Diese Waschmaschine ist alt. Der Techniker kommt früh."
        let out = TagSuggester.suggest(text: text, existing: [], libraryTags: [])
        XCTAssertEqual(out.first, "waschmaschine")
        XCTAssertFalse(out.contains("diese"))
        XCTAssertTrue(out.allSatisfy { TagEdit.normalized($0) == $0 })
    }

    func testParseModelAnswer() {
        XCTAssertEqual(TagSuggester.parse("rezept, Kochen, #italien\n- schnelle küche\n1. pasta, rezept, 2024"),
                       ["rezept", "kochen", "italien", "schnelle-küche", "pasta"])
        XCTAssertEqual(TagSuggester.parse("a, b, c, d, e, f, g, h", limit: 3), ["a", "b", "c"])
        XCTAssertEqual(TagSuggester.parse(""), [])
    }
}

/// Answers Ollama requests from a table instead of the network.
final class OllamaStub: URLProtocol {
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var failWith: URLError.Code?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let code = Self.failWith { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { s in
            s.open(); defer { s.close() }
            var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            return d
        }
        let (status, body) = Self.routes[request.url?.path ?? ""] ?? (404, "404 page not found")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class OllamaClientTests: XCTestCase {
    var session: URLSession!

    override func setUp() {
        OllamaStub.routes = [:]
        OllamaStub.failWith = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OllamaStub.self]
        session = URLSession(configuration: config)
    }

    func testOnlyLocalAddresses() {
        XCTAssertNotNil(OllamaClient.localURL("http://localhost:11434"))
        XCTAssertNotNil(OllamaClient.localURL("127.0.0.1:11434"))
        XCTAssertNotNil(OllamaClient.localURL("http://[::1]:11434"))
        XCTAssertNotNil(OllamaClient.localURL("http://ollama.localhost"))
        XCTAssertNil(OllamaClient.localURL("http://example.com:11434"))
        XCTAssertNil(OllamaClient.localURL("http://localhost.example.com"))
        XCTAssertNil(OllamaClient.localURL("http://192.168.1.5:11434"))
        XCTAssertNil(OllamaClient.localURL("file:///tmp"))
        XCTAssertThrowsError(try OllamaClient(baseURL: "https://api.example.com", model: "x")) {
            XCTAssertEqual($0 as? OllamaClient.Failure, .notLocal("https://api.example.com"))
        }
    }

    func testStreamPieces() {
        XCTAssertEqual(OllamaClient.piece(#"{"message":{"role":"assistant","content":"Hal"},"done":false}"#)?.content, "Hal")
        XCTAssertEqual(OllamaClient.piece(#"{"done":true}"#)?.done, true)
        XCTAssertEqual(OllamaClient.piece(#"{"error":"kaputt"}"#)?.error, "kaputt")
        XCTAssertNil(OllamaClient.piece("kein json"))
    }

    func testModelsAndChat() async throws {
        OllamaStub.routes["/api/tags"] = (200, #"{"models":[{"name":"qwen3:4b"},{"name":"llama3.2:latest"}]}"#)
        OllamaStub.routes["/api/chat"] = (200, """
        {"message":{"role":"assistant","content":"Hallo "},"done":false}
        {"message":{"role":"assistant","content":"Welt"},"done":false}
        {"message":{"role":"assistant","content":""},"done":true}
        """)
        let client = try OllamaClient(baseURL: "localhost:11434", model: "qwen3:4b", session: session)
        let models = try await client.models()
        XCTAssertEqual(models, ["llama3.2:latest", "qwen3:4b"])
        let answer = try await client.chat(system: "sys", prompt: "frage")
        XCTAssertEqual(answer, "Hallo Welt")
        let body = try XCTUnwrap(OllamaStub.lastBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.contains("\"model\":\"qwen3:4b\"") && body.contains("frage") && body.contains("sys"))
    }

    func testErrors() async throws {
        let empty = try OllamaClient(baseURL: "localhost:11434", model: "", session: session)
        do { _ = try await empty.chat(system: "", prompt: "x"); XCTFail() } catch { XCTAssertEqual(error as? OllamaClient.Failure, .noModel) }

        OllamaStub.routes["/api/chat"] = (404, #"{"error":"model \"mistral\" not found, try pulling it first"}"#)
        let missing = try OllamaClient(baseURL: "localhost:11434", model: "mistral", session: session)
        do { _ = try await missing.chat(system: "", prompt: "x"); XCTFail() } catch { XCTAssertEqual(error as? OllamaClient.Failure, .modelMissing("mistral")) }

        OllamaStub.routes["/api/chat"] = (500, #"{"error":"out of memory"}"#)
        do { _ = try await missing.chat(system: "", prompt: "x"); XCTFail() } catch { XCTAssertEqual(error as? OllamaClient.Failure, .server("out of memory")) }

        OllamaStub.failWith = .cannotConnectToHost
        do { _ = try await missing.models(); XCTFail() } catch {
            guard case .notRunning = error as? OllamaClient.Failure else { return XCTFail("\(error)") }
        }
        for f in [OllamaClient.Failure.noModel, .notRunning("u"), .notLocal("u"), .modelMissing("m"), .server("s")] {
            XCTAssertFalse((f.errorDescription ?? "").isEmpty)
        }
    }
}

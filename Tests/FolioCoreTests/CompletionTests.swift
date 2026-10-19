import XCTest
@testable import FolioCore

final class CompletionContextTests: XCTestCase {
    func testReceiverAndPrefix() {
        let c = CompletionContext(code: "x = 1\nSystem.out.pri", offset: 20, language: "java")
        XCTAssertEqual(c.receiver, "System.out")
        XCTAssertEqual(c.prefix, "pri")
        XCTAssertEqual(c.line, 1)
        XCTAssertEqual(c.column, 14)
        XCTAssertEqual(CompletionContext(code: "foo(bar).ba", offset: 11, language: "js").receiver, "foo(bar)")
        XCTAssertNil(CompletionContext(code: "let abc", offset: 7, language: "swift").receiver)
        XCTAssertEqual(CompletionContext(code: "std::ve", offset: 7, language: "cpp").receiver, "std")
    }

    func testWordsAndFilter() {
        let ctx = CompletionContext(code: "let counter = 1\nco", offset: 18, language: "swift")
        let labels = WordCompleter.complete(ctx).map(\.label)
        XCTAssertTrue(labels.contains("counter"))
        XCTAssertTrue(labels.contains("convenience"))
    }
}

final class LSPCompleterTests: XCTestCase {
    private func complete(_ code: String, _ lang: String) async throws -> [String] {
        guard LSPCompleter.shared.supports(lang) else { throw XCTSkip("kein Sprachserver für \(lang)") }
        let ctx = CompletionContext(code: code, offset: (code as NSString).length, language: lang)
        var labels: [String] = []
        for attempt in 0..<6 where labels.isEmpty {   // the server may still be parsing headers
            if attempt > 0 { try await Task.sleep(for: .seconds(1)) }
            labels = await LSPCompleter.shared.complete(ctx).map(\.label)
        }
        return labels
    }

    func testClangd() async throws {
        let labels = try await complete("#include <string>\nint main() { std::string s; s.app", "cpp")
        XCTAssertTrue(labels.contains("append"), "\(labels.prefix(20))")
    }

    func testSourceKit() async throws {
        let labels = try await complete("let s = \"abc\"\nlet n = s.upp", "swift")
        XCTAssertTrue(labels.contains { $0.hasPrefix("uppercased") }, "\(labels.prefix(20))")
    }
}

final class LSPClangdSimpleTests: XCTestCase {
    func testStruct() async throws {
        guard LSPCompleter.shared.supports("c") else { throw XCTSkip("kein clangd") }
        let code = "struct P { int xval; };\nint main(void) { struct P p; p.xv"
        let ctx = CompletionContext(code: code, offset: (code as NSString).length, language: "c")
        let labels = await LSPCompleter.shared.complete(ctx).map(\.label)
        XCTAssertTrue(labels.contains("xval"), "\(labels)")
    }
}

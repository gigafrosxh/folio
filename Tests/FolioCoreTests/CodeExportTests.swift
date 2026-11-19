import XCTest
import FolioCore

final class CodeExportTests: XCTestCase {
    private func temporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("source.txt")
    }

    func testNamesFromDefinitionsAndLanguageAliases() {
        XCTAssertEqual(CodeExport.suggestedFileName(code: "# comment\nasync def hello():\n pass", language: "py", caption: nil), "hello.py")
        XCTAssertEqual(CodeExport.suggestedFileName(code: "class Model:", language: "python", caption: "  "), "Model.py")
        XCTAssertEqual(CodeExport.suggestedFileName(code: "export function greet() {}", language: "js", caption: nil), "greet.js")
        for declaration in ["public func greet() {}", "struct greet {}", "final class greet {}"] {
            XCTAssertEqual(CodeExport.suggestedFileName(code: declaration, language: "swift", caption: nil), "greet.swift")
        }
        XCTAssertEqual(CodeExport.suggestedFileName(code: "println!(42)", language: "unknown", caption: nil), "code.txt")
        XCTAssertEqual(CodeExport.suggestedFileName(code: "", language: "plain", caption: nil), "code.txt")
    }

    func testCaptionExtensionAndSanitizing() {
        XCTAssertEqual(CodeExport.suggestedFileName(code: "def ignored():", language: "python", caption: " Report.JS "), "Report.JS")
        XCTAssertEqual(CodeExport.suggestedFileName(code: "", language: "swift", caption: "...a/b:c\nfile"), "a_b_c_file.swift")
        XCTAssertEqual(CodeExport.suggestedFileName(code: "", language: "python", caption: "..."), "code.py")
        let long = CodeExport.suggestedFileName(code: "", language: "swift", caption: String(repeating: "ä", count: 150) + ".py")
        XCTAssertEqual(long.count, 80)
        XCTAssertTrue(long.hasSuffix(".py"))
        XCTAssertFalse(long.hasPrefix("."))
    }

    func testContentsHaveExactlyOneNewline() {
        for source in ["hello", "hello\n", "hello\n\n", "hello\r\n\r\n"] {
            XCTAssertEqual(CodeExport.fileContents(code: source), Data("hello\n".utf8))
        }
        XCTAssertEqual(CodeExport.fileContents(code: ""), Data("\n".utf8))
        XCTAssertEqual(CodeExport.fileContents(code: "ä\nβ"), Data("ä\nβ\n".utf8))
    }

    func testWriteAndCompare() throws {
        let file = try temporaryFile()
        XCTAssertEqual(CodeExport.compare(code: "a", fileAt: file), .missing)
        try CodeExport.write(code: "ä\n", to: file)
        XCTAssertEqual(try Data(contentsOf: file), Data("ä\n".utf8))
        XCTAssertEqual(CodeExport.compare(code: "ä\n", fileAt: file), .same)
        XCTAssertEqual(CodeExport.compare(code: "ä", fileAt: file), .same)
        XCTAssertEqual(CodeExport.compare(code: "ä\r\n", fileAt: file), .same)
        XCTAssertEqual(CodeExport.compare(code: "other", fileAt: file), .differs)
        XCTAssertEqual(CodeExport.compare(code: "ä\n\n\n", fileAt: file), .differs)
        try Data("a\r\nb".utf8).write(to: file)
        XCTAssertEqual(CodeExport.compare(code: "a\nb\n", fileAt: file), .same)
        try CodeExport.write(code: "replacement", to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "replacement\n")
    }

    func testUnreadableFiles() throws {
        let file = try temporaryFile()
        try Data([0xff, 0xfe]).write(to: file)
        guard case .unreadable = CodeExport.compare(code: "", fileAt: file) else { return XCTFail("Expected invalid UTF-8") }
        try Data(repeating: 65, count: 5 * 1024 * 1024 + 1).write(to: file)
        XCTAssertEqual(CodeExport.compare(code: "", fileAt: file), .unreadable("Datei ist zu groß"))
        guard case .unreadable = CodeExport.compare(code: "", fileAt: file.deletingLastPathComponent()) else {
            return XCTFail("Expected directory rejection")
        }
    }
}

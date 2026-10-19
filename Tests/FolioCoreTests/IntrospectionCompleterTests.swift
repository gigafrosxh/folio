import Foundation
import XCTest
@testable import FolioCore

final class IntrospectionCompleterTests: XCTestCase {
    private func complete(_ code: String, language: String, tool: String) async throws -> [CompletionItem] {
        guard InterpreterLocator.shared.find(tool) != nil else { throw XCTSkip("\(tool) ist nicht installiert.") }
        return await IntrospectionCompleter().complete(CompletionContext(code: code, offset: (code as NSString).length, language: language))
    }

    func testJavaStaticField() async throws {
        let items = try await complete("System.ou", language: "java", tool: "javap")
        XCTAssertTrue(items.contains { $0.label == "out" && $0.kind == .field && $0.detail == "PrintStream" })
    }

    func testJavaFieldChain() async throws {
        let items = try await complete("System.out.pr", language: "java", tool: "javap")
        XCTAssertTrue(items.contains { $0.label == "println" })
        XCTAssertEqual(items.filter { $0.label == "println" }.count, 1)
    }

    func testJavaVariable() async throws {
        let items = try await complete("String s = \"x\"; s.len", language: "java", tool: "javap")
        XCTAssertTrue(items.contains { $0.label == "length" && $0.insertText == "length()" })
    }

    func testPythonModule() async throws {
        let items = try await complete("import os\nos.pa", language: "python", tool: "python3")
        XCTAssertTrue(items.contains { $0.label == "path" && $0.kind == .module })
    }

    func testPythonFunction() async throws {
        let items = try await complete("import math\nmath.sq", language: "python", tool: "python3")
        XCTAssertTrue(items.contains { $0.label == "sqrt" })
    }

    func testPythonLiteralVariable() async throws {
        let items = try await complete("x = \"hi\"\nx.up", language: "python", tool: "python3")
        XCTAssertTrue(items.contains { $0.label == "upper" })
    }

    func testJavaScriptGlobal() async throws {
        let items = try await complete("Math.fl", language: "javascript", tool: "node")
        XCTAssertTrue(items.contains { $0.label == "floor" })
    }

    func testJavaScriptModule() async throws {
        let items = try await complete("const fs = require('fs')\nfs.readF", language: "javascript", tool: "node")
        XCTAssertTrue(items.contains { $0.label == "readFileSync" })
    }

    func testPythonRejectsExecutableImportSuffix() async throws {
        let items = try await complete("import math; raise SystemExit()\nmath.sq", language: "python", tool: "python3")
        XCTAssertTrue(items.isEmpty)
    }

    func testPythonDoesNotCallConstructors() async throws {
        let items = try await complete("from pathlib import Path\nx = Path(unknown())\nx.exi", language: "python", tool: "python3")
        XCTAssertTrue(items.contains { $0.label == "exists" })
    }

    func testPythonDunderCacheFiltering() async throws {
        let ordinary = try await complete("str.up", language: "python", tool: "python3")
        XCTAssertFalse(ordinary.contains { $0.label.hasPrefix("__") })
        let underscored = try await complete("str.__le", language: "python", tool: "python3")
        XCTAssertTrue(underscored.contains { $0.label == "__len__" })
    }

    func testTypeScriptLiteral() async throws {
        let items = try await complete("const names: string[] = []\nnames.pu", language: "typescript", tool: "node")
        XCTAssertTrue(items.contains { $0.label == "push" })
    }

    func testPythonWildcardImport() async throws {
        let items = try await complete("from math import *\nsq", language: "python", tool: "python3")
        XCTAssertTrue(items.contains { $0.label == "sqrt" && $0.kind == .function })
    }

    func testPythonModuleDiscovery() async throws {
        let items = try await complete("import jso", language: "python", tool: "python3")
        XCTAssertTrue(items.contains { $0.label == "json" && $0.kind == .module })
    }

    func testPythonQuotedReceiver() async throws {
        let items = try await complete("\"abc\".up", language: "python", tool: "python3")
        XCTAssertTrue(items.contains { $0.label == "upper" })
    }

    func testJavaMethodChain() async throws {
        let items = try await complete("System.getProperties().getP", language: "java", tool: "javap")
        XCTAssertTrue(items.contains { $0.label == "getProperty" })
    }

    func testJavaImportedVariable() async throws {
        let items = try await complete("import java.util.*;\nvar scanner = new Scanner(System.in);\nscanner.nextL", language: "java", tool: "javap")
        XCTAssertTrue(items.contains { $0.label == "nextLine" })
    }

    func testJavaScriptImportedModule() async throws {
        let items = try await complete("import * as fs from 'fs'\nfs.readF", language: "typescript", tool: "node")
        XCTAssertTrue(items.contains { $0.label == "readFileSync" })
    }
}

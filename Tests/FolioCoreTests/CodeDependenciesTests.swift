import XCTest
@testable import FolioCore

final class CodeDependenciesTests: XCTestCase {
    private func item(_ code: String, _ lang: String = "python", session: Bool = true, ran: Date? = nil, ok: Bool = true) -> CodeDependencies.Item {
        var item = CodeDependencies.Item(id: UUID(), language: lang, session: session ? lang : nil, code: code, lastRun: nil)
        if let ran { item.lastRun = CodeRunStamp(ranAt: ran, codeHash: item.fingerprint, succeeded: ok, upstream: []) }
        return item
    }

    func testPythonDefinitionsAndUses() {
        let s = SymbolScan.scan(
            """
            import pandas as pd
            from math import sqrt, pi as PI
            df = pd.read_csv("x.csv")  # comment mentions total
            a, b = 1, 2
            def area(r): return PI * r * r
            class Shape: pass
            for i in range(3): print(i)
            """, language: "python")
        XCTAssertTrue(s.defines.isSuperset(of: ["pd", "sqrt", "PI", "df", "a", "b", "area", "Shape", "i"]))
        XCTAssertFalse(s.defines.contains("pandas"))
        XCTAssertTrue(s.uses.contains("pd"))
        XCTAssertFalse(s.uses.contains("total"), "names in comments do not count")
        XCTAssertFalse(s.uses.contains("csv"), "names in strings do not count")
    }

    func testEdgesPointToNearestEarlierDefiner() {
        let a = item("x = 1\ny = 2"), b = item("x = 10"), c = item("print(x + y)")
        let g = CodeDependencies.build([a, b, c])
        XCTAssertEqual(Set(g.upstream(of: c.id).map(\.from)), [a.id, b.id])
        XCTAssertEqual(g.upstream(of: c.id).first { $0.from == b.id }?.names, ["x"])
        XCTAssertEqual(g.upstream(of: c.id).first { $0.from == a.id }?.names, ["y"])
        XCTAssertTrue(g.upstream(of: b.id).isEmpty, "redefining x is not a use of x")
    }

    func testSelfUpdateDependsOnEarlierBlock() {
        let a = item("total = 0"), b = item("total += 5")
        XCTAssertEqual(CodeDependencies.build([a, b]).upstream(of: b.id).map(\.from), [a.id])
    }

    func testSessionsAndIsolatedBlocksStayApart() {
        let a = item("x = 1"), b = item("console.log(x)", "javascript"), c = item("print(x)", session: false)
        let g = CodeDependencies.build([a, b, c])
        XCTAssertTrue(g.edges.isEmpty)
    }

    func testJavaScriptDefinitions() {
        let s = SymbolScan.scan("const a = 1; let {b, c} = obj; function f() {}\nimport fs from 'fs'\nimport { readFile as rf } from 'fs'", language: "javascript")
        XCTAssertTrue(s.defines.isSuperset(of: ["a", "b", "c", "f", "fs", "rf"]))
    }

    func testKeywordArgumentsAreNotUses() {
        let s = SymbolScan.scan("plot(data, color=red)", language: "python")
        XCTAssertFalse(s.uses.contains("color"))
        XCTAssertTrue(s.uses.contains("red"))
    }

    func testOrderWarning() {
        let a = item("print(later)"), b = item("later = 1")
        let g = CodeDependencies.build([a, b])
        XCTAssertEqual(g.warnings, [.init(block: a.id, name: "later", definedIn: b.id)])
    }

    func testStatus() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let a = item("x = 1", ran: t0)
        var b = item("print(x)")
        b.lastRun = CodeDependencies.build([a, b]).runStamp(for: b, succeeded: true)
        b.lastRun?.ranAt = t0.addingTimeInterval(5)
        var g = CodeDependencies.build([a, b])
        XCTAssertEqual(g.status[a.id], .ok)
        XCTAssertEqual(g.status[b.id], .ok)

        // Upstream ran again later → downstream is stale.
        var a2 = a
        a2.lastRun?.ranAt = t0.addingTimeInterval(10)
        g = CodeDependencies.build([a2, b])
        XCTAssertEqual(g.status[b.id], .stale("Abhängigkeiten seit der letzten Ausführung geändert"))
        XCTAssertEqual(g.staleInOrder, [b.id])

        // Code changed since the run → stale, and it propagates.
        var a3 = a
        a3.code = "x = 2"
        g = CodeDependencies.build([a3, b])
        XCTAssertEqual(g.status[a3.id], .stale("Code oder Ausführungseinstellungen geändert"))
        XCTAssertEqual(g.status[b.id], .stale("Block 1 ist veraltet"))

        // Upstream never ran.
        var unrun = item("x = 1")
        unrun.id = a.id
        b.lastRun = CodeDependencies.build([unrun, b]).runStamp(for: b, succeeded: true)
        g = CodeDependencies.build([unrun, b])
        XCTAssertEqual(g.status[b.id], .stale("Block 1 wurde nicht ausgeführt"))

        // Failed run.
        g = CodeDependencies.build([item("boom()", ran: t0, ok: false)])
        XCTAssertEqual(g.status.values.first, .failed)
    }

    func testSavedDependenciesDetectRemovedAndReboundNames() throws {
        let time = Date()
        let source = item("x = 1\ny = 2", ran: time)
        let replacement = item("x = 2", ran: time)
        var use = item("print(x, y)")
        let graph = CodeDependencies.build([source, use])
        let stamp = graph.runStamp(for: use, succeeded: true)
        use.lastRun = try JSONDecoder().decode(CodeRunStamp.self, from: JSONEncoder().encode(stamp))
        XCTAssertEqual(use.lastRun?.upstream?.first?.names, ["x", "y"])
        XCTAssertEqual(CodeDependencies.build([source, use]).status[use.id], .ok)
        XCTAssertTrue(CodeDependencies.build([use]).status[use.id]!.isStale)
        XCTAssertTrue(CodeDependencies.build([source, replacement, use]).status[use.id]!.isStale)
        var renamed = source
        renamed.code = "y = 2"
        let renamedHash = renamed.fingerprint
        renamed.lastRun?.codeHash = renamedHash
        XCTAssertTrue(CodeDependencies.build([renamed, use]).status[use.id]!.isStale)
        var restored = source
        restored.lastRun?.ranAt = time.addingTimeInterval(-1)
        XCTAssertTrue(CodeDependencies.build([restored, use]).status[use.id]!.isStale)
    }

    func testRunInputsInvalidateSavedResult() {
        var block = item("print(1)", ran: Date())
        let original = block
        for change: (inout CodeDependencies.Item) -> Void in [
            { $0.stdin = " " }, { $0.interactive = true }, { $0.isolated = true }, { $0.language = "swift" }
        ] {
            block = original
            change(&block)
            XCTAssertTrue(CodeDependencies.build([block]).status[block.id]!.isStale)
        }
    }

    func testLegacyStampDecodesWithUnknownDependencies() throws {
        let json = Data(#"{"ranAt":0,"codeHash":"abc","succeeded":true}"#.utf8)
        var block = item("print(1)")
        block.lastRun = try JSONDecoder().decode(CodeRunStamp.self, from: json)
        XCTAssertNil(block.lastRun?.upstream)
        XCTAssertTrue(CodeDependencies.build([block]).status[block.id]!.isStale)
    }

    func testFingerprintIgnoresTrailingWhitespaceAndCRLF() {
        XCTAssertEqual(CodeDependencies.fingerprint("a = 1\r\nb = 2\n\n"), CodeDependencies.fingerprint("a = 1\nb = 2"))
        XCTAssertNotEqual(CodeDependencies.fingerprint("a = 1"), CodeDependencies.fingerprint("a = 2"))
    }

    func testRunStampSurvivesSaving() throws {
        var r = BlockRecord(kind: .code)
        r.code = "x = 1"
        r.lastRun = CodeRunStamp(ranAt: Date(timeIntervalSince1970: 42), codeHash: "abc", succeeded: true)
        r.linkedFile = "/tmp/x.py"
        let decoded = try JSONDecoder().decode(BlockRecord.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(decoded.lastRun, r.lastRun)
        XCTAssertEqual(decoded.linkedFile, "/tmp/x.py")
    }
}

import XCTest
@testable import ComplexityCore

final class CognitiveComplexityTests: XCTestCase {
    private func score(_ body: String) -> Int {
        ComplexityScanner.units(in: "func f() {\n\(body)\n}", file: "a.swift").first!.raw
    }

    func testStraightCodeIsZero() {
        XCTAssertEqual(score("let a = 1\nprint(a)"), 0)
    }

    func testIfElseIfElse() {
        XCTAssertEqual(score("if a { } else if b { } else { }"), 3)
    }

    func testNestingAddsLevel() {
        // if (1) > for (1 + 1) > if (1 + 2)
        XCTAssertEqual(score("if a { for x in y { if b { } } }"), 6)
    }

    func testGuardCountsWithoutNesting() {
        XCTAssertEqual(score("guard a else { return }\nif b { }"), 2)
        XCTAssertEqual(score("if c { guard a else { return } }"), 2)
    }

    func testSwitchCountsOnceAndNestsCases() {
        XCTAssertEqual(score("switch x {\ncase 1: if a { }\ndefault: break\n}"), 3)
    }

    func testLogicalChains() {
        XCTAssertEqual(score("if a && b && c { }"), 2)
        XCTAssertEqual(score("if a && b || c { }"), 3)
    }

    func testTernaryAndCatch() {
        XCTAssertEqual(score("let x = a ? 1 : 2"), 1)
        XCTAssertEqual(score("do { try f() } catch { if a { } }"), 3)
    }

    func testClosuresNestWithoutCounting() {
        XCTAssertEqual(score("items.forEach { x in if x { } }"), 2)
    }

    func testLabeledJumps() {
        XCTAssertEqual(score("outer: for a in b { for c in d { continue outer } }"), 4)
    }

    func testUnitsKindsAndNames() {
        let source = """
        struct S {
            var stored = 1 { didSet { if a { } } }
            var computed: Int { a ? 1 : 2 }
            init(x: Int) { }
            func run(_ a: Int, to b: Int) { func inner() { if c { } } }
        }
        extension S { var body: some View { Text("") } }
        """
        let units = ComplexityScanner.units(in: source, file: "S.swift")
        XCTAssertEqual(units.map(\.symbol), ["S.computed", "S.init(x:)", "S.run(_:to:)", "S.body"])
        XCTAssertEqual(units.map(\.kind), [.property, .initializer, .method, .property])
        XCTAssertEqual(units[2].raw, 2, "nested function: if at nesting 1")
        XCTAssertEqual(units[0].line, 3)
    }

    func testScoreIsClamped() {
        let unit = Unit(file: "a", line: 1, symbol: "f", kind: .method, raw: 0)
        XCTAssertEqual(unit.score, 1)
        XCTAssertEqual(Unit(file: "a", line: 1, symbol: "f", kind: .method, raw: 140).score, 100)
    }

    func testReportFailsOnlyNewOrWorse() {
        let units = [Unit(file: "a", line: 1, symbol: "old", kind: .method, raw: 20), Unit(file: "a", line: 2, symbol: "worse", kind: .method, raw: 30),
                     Unit(file: "a", line: 3, symbol: "new", kind: .method, raw: 16), Unit(file: "a", line: 4, symbol: "ok", kind: .method, raw: 15)]
        let report = ComplexityReport(units: units, baseline: ["a|old": 20, "a|worse": 25, "a|gone": 40])
        XCTAssertEqual(report.violations.map(\.symbol).sorted(), ["new", "worse"])
        XCTAssertEqual(report.resolved, ["a|gone"])
        XCTAssertEqual(report.distribution.map(\.count), [0, 0, 1, 3, 0])
        XCTAssertTrue(report.markdown.contains("| a | 3 | `new` | method | 16 | 16 | neu |"))
    }
}

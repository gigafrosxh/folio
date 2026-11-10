import XCTest
@testable import FolioCore

final class BlockTestingTests: XCTestCase {
    private func result(_ out: String, err: String = "", exit: Int32 = 0, timedOut: Bool = false, cancelled: Bool = false) -> RunResult {
        RunResult(stdout: out, stderr: err, exitCode: exit, duration: 0, command: "x", timedOut: timedOut, cancelled: cancelled)
    }

    func testExactIgnoresLineEndingsAndTrailingSpace() {
        let test = BlockTest(expectedOutput: "a\n  b\n")
        XCTAssertEqual(BlockTestEvaluator.evaluate(test, result: result("a  \r\n  b\r\n\n")).status, .passed)
        XCTAssertEqual(BlockTestEvaluator.evaluate(test, result: result("a\nb\n")).status, .failed)
    }

    func testExitCode() {
        let outcome = BlockTestEvaluator.evaluate(BlockTest(expectedExitCode: 0), result: result("", exit: 3))
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.actualExitCode, 3)
        XCTAssertEqual(BlockTestEvaluator.evaluate(BlockTest(expectedExitCode: 3), result: result("", exit: 3)).status, .passed)
    }

    func testContainsAndRegex() {
        XCTAssertEqual(BlockTestEvaluator.evaluate(BlockTest(expectedOutput: "lo w", match: .contains), result: result("hello world")).status, .passed)
        XCTAssertEqual(BlockTestEvaluator.evaluate(BlockTest(expectedOutput: "^\\d+$", match: .regex), result: result("x\n42\n")).status, .passed)
        let invalid = BlockTestEvaluator.evaluate(BlockTest(expectedOutput: "(", match: .regex), result: result("x"))
        XCTAssertEqual(invalid.status, .failed)
        XCTAssertEqual(invalid.messages, ["Der reguläre Ausdruck ist ungültig."])
    }

    func testStoppedTimedOutAndEmpty() {
        XCTAssertEqual(BlockTestEvaluator.evaluate(BlockTest(), result: result("", cancelled: true)).status, .notRun)
        XCTAssertEqual(BlockTestEvaluator.evaluate(BlockTest(), result: result("", timedOut: true)).status, .failed)
        XCTAssertEqual(BlockTestEvaluator.evaluate(BlockTest(expectedExitCode: nil), result: result("")).status, .notRun)
    }

    func testEmptyExpectationMeansNoOutput() {
        XCTAssertEqual(BlockTestEvaluator.evaluate(BlockTest(expectedOutput: ""), result: result("\n")).status, .passed)
        XCTAssertEqual(BlockTestEvaluator.evaluate(BlockTest(expectedOutput: ""), result: result("x")).status, .failed)
    }

    func testPlanRunsSetupOnlyForLaterTestsOfTheSameSession() {
        let ids = (0..<6).map { _ in UUID() }
        let items = [
            BlockTestPlan.Item(id: ids[0], hasTest: false, session: "python"),
            BlockTestPlan.Item(id: ids[1], hasTest: true, session: "python"),
            BlockTestPlan.Item(id: ids[2], hasTest: false, session: "python"),
            BlockTestPlan.Item(id: ids[3], hasTest: false),
            BlockTestPlan.Item(id: ids[4], hasTest: true, interactive: true),
            BlockTestPlan.Item(id: ids[5], hasTest: false, session: "node"),
        ]
        let steps = BlockTestPlan.steps(for: items)
        XCTAssertEqual(steps.map(\.id), [ids[0], ids[1], ids[4]])
        XCTAssertEqual(steps[0].action, .setup)
        XCTAssertEqual(steps[1].action, .test)
        if case .skip = steps[2].action {} else { XCTFail("interaktiv muss übersprungen werden") }
    }

    func testRoundTripAndOldBlocks() throws {
        var block = BlockRecord(kind: .code)
        block.test = BlockTest(expectedOutput: "42", expectedExitCode: nil, match: .contains)
        let again = try JSONDecoder().decode(BlockRecord.self, from: JSONEncoder().encode(block))
        XCTAssertEqual(again.test, block.test)

        let old = #"{"id":"\#(UUID().uuidString)","kind":"code"}"#
        XCTAssertNil(try JSONDecoder().decode(BlockRecord.self, from: Data(old.utf8)).test)
        let odd = #"{"expectedExitCode":"x","match":"zukunft"}"#
        let tolerant = try JSONDecoder().decode(BlockTest.self, from: Data(odd.utf8))
        XCTAssertNil(tolerant.expectedExitCode)
        XCTAssertEqual(tolerant.match, .exact)
    }
}

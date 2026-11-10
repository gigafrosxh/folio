import XCTest
@testable import FolioCore

/// The session protocol and concurrent or stopped runs (#142).
final class CodeExecutionRegressionTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }
    private let m = "\u{1E}"

    func testPlainTextIsPassedOn() {
        XCTAssertEqual(KernelFrame.next(in: data("hallo")), KernelFrame(text: "hallo", consumed: 5, marker: nil, continues: false))
        XCTAssertNil(KernelFrame.next(in: Data()))
    }

    func testCompleteMarkerEndsWithStatus() {
        let frame = KernelFrame.next(in: data("x\n\(m)abc:ok\nrest"))
        XCTAssertEqual(frame, KernelFrame(text: "x\n", consumed: 10, marker: .init(id: "abc", status: "ok"), continues: true))
    }

    func testIncompleteMarkerWaitsAndKeepsIt() {
        XCTAssertEqual(KernelFrame.next(in: data("x\(m)abc")), KernelFrame(text: "x", consumed: 1, marker: nil, continues: false))
        XCTAssertEqual(KernelFrame.next(in: data("\(m)abc")), KernelFrame(text: "", consumed: 0, marker: nil, continues: false))
    }

    func testMalformedMarkerIsDropped() {
        XCTAssertEqual(KernelFrame.next(in: data("\(m)ohne-status\n")), KernelFrame(text: "", consumed: 13, marker: nil, continues: true))
    }

    func testStatusMayContainColons() {
        XCTAssertEqual(KernelFrame.next(in: data("\(m)a:error:1\n"))?.marker, .init(id: "a", status: "error:1"))
    }

    func testParallelRunsDoNotMixOutput() async throws {
        let bash = Languages.spec(for: "bash")
        async let first = CodeRun().run(code: "for i in 1 2 3; do echo A; sleep 0.05; done", language: bash)
        async let second = CodeRun().run(code: "for i in 1 2 3; do echo B 1>&2; sleep 0.05; done", language: bash)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.stdout, "A\nA\nA\n")
        XCTAssertEqual(a.stderr, "")
        XCTAssertEqual(b.stdout, "")
        XCTAssertEqual(b.stderr, "B\nB\nB\n")
    }

    func testCancelStopsTheProcess() async throws {
        let run = CodeRun()
        async let result = run.run(code: "echo los; sleep 20", language: Languages.spec(for: "bash"), timeout: 30)
        try await Task.sleep(for: .milliseconds(500))
        run.cancel()
        let r = try await result
        XCTAssertTrue(r.cancelled)
        XCTAssertLessThan(r.duration, 10)
        XCTAssertEqual(r.stdout, "los\n")
    }

    func testPreparedInputReachesTheProgram() async throws {
        let options = RunOptions(stdin: "eingabe", interactive: false, workingDirectory: nil, environment: [:], limits: ResourceLimits())
        let r = try await CodeRun().run(code: "read x; echo \"[$x]\"", language: Languages.spec(for: "bash"), options: options, onOutput: nil, onServer: nil)
        XCTAssertEqual(r.stdout, "[eingabe]\n")
    }

    func testKernelStillWorksAfterAnError() async throws {
        let k = try Kernel(language: KernelLanguages.python)
        defer { k.shutdown() }
        let bad = await k.execute("1/0", timeout: 10)
        XCTAssertFalse(bad.succeeded)
        XCTAssertTrue(bad.stderr.contains("ZeroDivisionError"), bad.stderr)
        let good = await k.execute("print(40 + 2)", timeout: 10)
        XCTAssertTrue(good.succeeded)
        XCTAssertEqual(good.stdout.trimmingCharacters(in: .newlines), "42")
    }
}

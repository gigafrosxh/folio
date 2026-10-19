import XCTest
@testable import FolioCore

final class KernelTests: XCTestCase {
    func testPythonSharesState() async throws {
        guard InterpreterLocator.shared.find("python3") != nil else { throw XCTSkip("kein python3") }
        let k = try Kernel(language: KernelLanguages.python)
        defer { k.shutdown() }
        let a = await k.execute("a = 10\nprint('set')")
        XCTAssertEqual(a.stdout, "set\n")
        let b = await k.execute("print(a)\na * 2")
        XCTAssertEqual(b.stdout, "10\n20\n")
        XCTAssertTrue(b.succeeded)
        let c = await k.execute("1/0")
        XCTAssertFalse(c.succeeded)
        XCTAssertTrue(c.stderr.contains("ZeroDivisionError"), c.stderr)
        let names = await k.complete(receiver: nil)
        XCTAssertTrue(names.contains("a"))
        let members = await k.complete(receiver: "a")
        XCTAssertTrue(members.contains("bit_length"))
    }

    func testTimeoutInterruptsButKeepsSession() async throws {
        guard InterpreterLocator.shared.find("python3") != nil else { throw XCTSkip("kein python3") }
        let k = try Kernel(language: KernelLanguages.python)
        defer { k.shutdown() }
        _ = await k.execute("x = 5")
        let r = await k.execute("import time\ntime.sleep(10)", timeout: 1)
        XCTAssertTrue(r.timedOut)
        let after = await k.execute("print(x)")
        XCTAssertEqual(after.stdout, "5\n")
    }

    func testQueuedRuns() async throws {
        guard InterpreterLocator.shared.find("python3") != nil else { throw XCTSkip("kein python3") }
        let k = try Kernel(language: KernelLanguages.python)
        defer { k.shutdown() }
        let one = Task { await k.execute("import time\ntime.sleep(0.3)\nn = 1") }
        try await Task.sleep(for: .milliseconds(50))
        let r2 = await k.execute("print(n)")   // waits for the first run
        _ = await one.value
        XCTAssertEqual(r2.stdout, "1\n")
    }
}

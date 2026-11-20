import XCTest

@testable import FolioCore

/// Milestone 1.11.2: process groups, bounded draining, cancellation, server detection, UTF-8 streaming, output
/// budget and the session kernel (#287–#300).
private let bashSpec = Languages.spec(for: "bash")

final class ProcessLifecycleTests: XCTestCase {

    // #294
    func testUTF8StreamKeepsCharactersAcrossChunks() {
        let text = "Grüße 👋🏽 – ok"
        let bytes = Array(text.utf8)
        for split in 1..<bytes.count {
            var stream = UTF8Stream()
            let a = stream.decode(Data(bytes[..<split]))
            let b = stream.decode(Data(bytes[split...]))
            XCTAssertEqual(a + b + stream.flush(), text, "Teilung bei \(split)")
            XCTAssertFalse((a + b).contains("\u{FFFD}"))
        }
        // The kernel's reader holds a split character back too.
        let partial = Data(Array("ä".utf8).prefix(1))
        XCTAssertEqual(KernelFrame.next(in: Data("x".utf8) + partial)?.consumed, 1)
    }

    // #287
    func testBackgroundChildWithOpenPipeDoesNotHangTheRun() async throws {
        var options = RunOptions(limits: ResourceLimits(timeout: 20, killOrphans: false))
        options.stdin = nil
        let start = Date()
        let r = try await CodeRun().run(code: "(sleep 30) &\necho fertig", language: bashSpec, options: options)
        XCTAssertLessThan(Date().timeIntervalSince(start), 8, "Lauf endet, obwohl ein Hintergrundprozess die Ausgabe offen hält")
        XCTAssertEqual(r.stdout, "fertig\n")
        XCTAssertFalse(r.timedOut)
        _ = try? await CodeRun().run(code: "pkill -f 'sleep 30' || true", language: bashSpec)
    }

    // #289
    func testShortLivedParentLeavesNoBackgroundJobs() async throws {
        let marker = "folio-orphan-\(UUID().uuidString.prefix(8))"
        let r = try await CodeRun().run(code: "bash -c 'exec -a \(marker) sleep 30' &\nexit 0", language: bashSpec)
        XCTAssertEqual(r.exitCode, 0)
        try await Task.sleep(for: .milliseconds(500))
        let left = try await CodeRun().run(code: "pgrep -f \(marker) || true", language: bashSpec)
        XCTAssertEqual(left.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "", "kein verwaister Prozess")
    }

    // #288
    func testIdentityRefusesAReusedPid() throws {
        let me = try XCTUnwrap(ProcessIdentity.of(getpid()))
        XCTAssertTrue(me.isAlive)
        let impostor = ProcessIdentity(pid: me.pid, started: me.started + 1)
        XCTAssertFalse(impostor.isAlive, "gleiche PID, anderer Start: ein fremder Prozess")
        XCTAssertFalse(impostor.signal(0))
        XCTAssertNil(ProcessIdentity.of(999_999))
    }

    // #290
    func testCancelBeforeAndDuringLaunch() async throws {
        let early = CodeRun()
        early.cancel()
        let r = try await early.run(code: "sleep 5; echo nie", language: bashSpec)
        XCTAssertTrue(r.cancelled)
        XCTAssertEqual(r.stdout, "")
        for delay in [0, 5, 20] {
            let run = CodeRun()
            let start = Date()
            async let result = run.run(code: "sleep 10", language: bashSpec)
            try await Task.sleep(for: .milliseconds(delay))
            run.cancel()
            let done = try await result
            XCTAssertTrue(done.cancelled)
            XCTAssertLessThan(Date().timeIntervalSince(start), 5, "Abbruch nach \(delay) ms wirkt")
        }
    }

    // #291
    func testPrintedAddressAloneKeepsTheTimeout() async throws {
        let r = try await CodeRun().run(code: "echo 'Running on http://localhost:59999'\nsleep 20", language: bashSpec, timeout: 2)
        XCTAssertTrue(r.timedOut, "ohne lauschenden Port kein Server")
        XCTAssertNil(r.serverURL)
    }

    // #295
    func testLiveOutputStaysWithinBudget() async throws {
        let streamed = LockedCount()
        var options = RunOptions(limits: ResourceLimits(timeout: 20, maxOutputBytes: 50_000))
        options.stdin = nil
        let r = try await CodeRun().run(
            code: "head -c 3000000 /dev/zero | tr '\\\\0' 'x'", language: bashSpec, options: options, onOutput: { streamed.add($0) })
        XCTAssertLessThan(streamed.bytes, 400_000, "Live-Ausgabe begrenzt")
        XCTAssertTrue(streamed.text.contains("nicht mehr live"))
        XCTAssertLessThan(r.stdout.utf8.count, 200_000)
    }

    // #299: the PATH lookup of the login shell is bounded even if the shell does not cooperate.
    func testLoginShellLookupIsBounded() {
        let start = Date()
        _ = InterpreterLocator().searchPath
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }

    // #292, #293, #296, #297, #298
    func testKernelLifecycle() async throws {
        let k = try Kernel(language: KernelLanguages.python)
        defer { k.shutdown() }
        // Order of streamed output (#298).
        let seen = LockedCount()
        _ = await k.execute("for i in range(200): print(i, flush=True)", onOutput: { seen.add($0) })
        let numbers = seen.text.split(separator: "\n").compactMap { Int($0) }
        XCTAssertEqual(numbers, Array(0..<200))
        // A manual interrupt is reported as cancelled, a timeout is not (#296).
        async let long = k.execute("import time\ntime.sleep(20)")
        try await Task.sleep(for: .seconds(1))
        // Completion answers at once while busy (#297).
        let start = Date()
        let names = await k.complete(receiver: nil)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(names, [])
        k.interrupt()
        let stopped = await long
        XCTAssertTrue(stopped.cancelled)
        let timed = await k.execute("import time\ntime.sleep(20)", timeout: 1)
        XCTAssertTrue(timed.timedOut)
        XCTAssertFalse(timed.cancelled)
        // Every waiting request returns when the interpreter ends (#293): one runs, two wait behind it.
        async let a = k.execute("import time\ntime.sleep(20)")
        try await Task.sleep(for: .milliseconds(500))
        async let b = k.execute("print(1)")
        async let c = k.execute("print(2)")
        try await Task.sleep(for: .milliseconds(300))
        kill(k.pid, SIGKILL)
        let begun = Date()
        let results = await [a, b, c]
        XCTAssertLessThan(Date().timeIntervalSince(begun), 5)
        XCTAssertTrue(results.allSatisfy { !$0.succeeded }, results.map(\.stderr).joined(separator: " | "))
        // Requests after the end fail right away (#292, #293).
        let after = await k.execute("print(3)")
        XCTAssertFalse(after.succeeded)
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String] = []
    func add(_ s: String) {
        lock.lock()
        parts.append(s)
        lock.unlock()
    }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return parts.joined()
    }
    var bytes: Int { text.utf8.count }
}

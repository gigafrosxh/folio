import XCTest
@testable import FolioCore

final class KernelMoreTests: XCTestCase {
    private func kernel(_ language: KernelLanguage) throws -> Kernel {
        guard InterpreterLocator.shared.find(language.command[0]) != nil else {
            throw XCTSkip("\(language.command[0]) ist nicht installiert.")
        }
        return try Kernel(language: language)
    }

    private func check(_ language: KernelLanguage, definition: String, read: String,
                       error: String, message: String, sleep: String) async throws {
        let k = try kernel(language)
        defer { k.shutdown() }
        let defined = await k.execute(definition)
        XCTAssertTrue(defined.succeeded, defined.stderr)
        let value = await k.execute(read)
        XCTAssertTrue(value.succeeded, value.stderr)
        XCTAssertEqual(value.stdout, "10\n")
        let failed = await k.execute(error)
        XCTAssertFalse(failed.succeeded)
        XCTAssertTrue(failed.stderr.contains(message), failed.stderr)
        let names = await k.complete(receiver: nil)
        XCTAssertTrue(names.contains("a"), "\(names)")
        let timeout = await k.execute(sleep, timeout: 1)
        XCTAssertTrue(timeout.timedOut)
        XCTAssertFalse(timeout.succeeded)
        let after = await k.execute(read)
        XCTAssertTrue(after.succeeded, after.stderr)
        XCTAssertEqual(after.stdout, "10\n")
    }

    func testJavaScript() async throws {
        try await check(KernelLanguages.javascript, definition: "const a = 10", read: "console.log(a)",
                        error: "throw new Error('Testfehler')", message: "Testfehler",
                        sleep: "new Promise(resolve => setTimeout(resolve, 5000))")
    }

    func testRuby() async throws {
        try await check(KernelLanguages.ruby, definition: "a = 10", read: "puts a",
                        error: "raise 'Testfehler'", message: "RuntimeError: Testfehler", sleep: "sleep 5")
    }

    func testBash() async throws {
        try await check(KernelLanguages.bash, definition: "a=10", read: "echo $a",
                        error: "echo Testfehler >&2; false", message: "Testfehler", sleep: "sleep 5")
        try await checkShellState(KernelLanguages.bash)
    }

    func testZsh() async throws {
        try await check(KernelLanguages.zsh, definition: "a=10", read: "echo $a",
                        error: "echo Testfehler >&2; false", message: "Testfehler", sleep: "sleep 5")
        try await checkShellState(KernelLanguages.zsh)
    }

    private func checkShellState(_ language: KernelLanguage) async throws {
        let k = try kernel(language)
        defer { k.shutdown() }
        let defined = await k.execute("text=\"Grüße 'Welt'\"\nzeigen() { printf '%s\\n' \"$text\"; }\ncd /")
        XCTAssertTrue(defined.succeeded, defined.stderr)
        let read = await k.execute("zeigen\npwd")
        XCTAssertEqual(read.stdout, "Grüße 'Welt'\n/\n")
        let names = await k.complete(receiver: nil)
        XCTAssertTrue(names.contains("zeigen"))
        let members = await k.complete(receiver: "text")
        XCTAssertTrue(members.isEmpty)
    }

    func testJavaScriptExpressionsAndAwait() async throws {
        let k = try kernel(KernelLanguages.javascript)
        defer { k.shutdown() }
        _ = await k.execute("const a = 10")
        let result = await k.execute("a * 2")
        XCTAssertEqual(result.stdout, "20\n")
        let awaited = await k.execute("const answer = await Promise.resolve(42)")
        XCTAssertTrue(awaited.succeeded, awaited.stderr)
        let later = await k.execute("answer")
        XCTAssertEqual(later.stdout, "42\n")
        let members = await k.complete(receiver: "a")
        XCTAssertTrue(members.contains("toFixed"))
        let invalid = await k.complete(receiver: "console.log('unerwünscht')")
        XCTAssertTrue(invalid.isEmpty)
    }
}

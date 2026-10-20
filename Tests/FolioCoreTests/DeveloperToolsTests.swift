import XCTest
@testable import FolioCore

final class DeveloperToolsTests: XCTestCase {
    private var python: LanguageSpec { Languages.spec(for: "python") }

    private func requirePython() throws {
        if InterpreterLocator.shared.find("python3") == nil { throw XCTSkip("python3 fehlt") }
    }

    // MARK: Environment (#25)

    func testVariablesParsing() {
        let vars = RunEnvironment.parseVariables("""
        # Kommentar
        API_URL=http://localhost:3000
        export TOKEN="geheim wert"
        LEER=
        1FALSCH=x
        ohne_gleich
        """)
        XCTAssertEqual(vars, ["API_URL": "http://localhost:3000", "TOKEN": "geheim wert", "LEER": ""])
        XCTAssertEqual(RunEnvironment.formatVariables(["B": "2", "A": "1"]), "A=1\nB=2")
        XCTAssertTrue(RunEnvironment().isEmpty)
        XCTAssertNil(RunEnvironment(workingDirectory: "/gibt/es/nicht").workingDirectoryURL)
        XCTAssertEqual(RunEnvironment(workingDirectory: "~").workingDirectoryURL?.path, FileManager.default.homeDirectoryForCurrentUser.path)
    }

    func testEnvironmentRoundTripsInMetadata() throws {
        var meta = NoteMetadata(title: "Umgebung")
        meta.environment = RunEnvironment(interpreters: ["python": "python3.12"], workingDirectory: "~/Projekte", variables: ["X": "1"], timeout: 90)
        let back = try JSONDecoder().decode(NoteMetadata.self, from: JSONEncoder().encode(meta))
        XCTAssertEqual(back.environment, meta.environment)
    }

    func testRunUsesWorkingDirectoryAndVariables() async throws {
        try requirePython()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await CodeRun().run(code: "import os\nprint(os.getcwd())\nprint(os.environ['FOLIO_TEST'])", language: python,
                                        options: RunOptions(workingDirectory: dir, environment: ["FOLIO_TEST": "hallo"]))
        let lines = r.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, dir.resolvingSymlinksInPath().path)
        XCTAssertEqual(lines.last, "hallo")
    }

    // MARK: Input (#24)

    func testPrefilledInput() async throws {
        try requirePython()
        let r = try await CodeRun().run(code: "name = input('Name? ')\nprint('Hallo', name)\nimport sys\nprint(len(sys.stdin.read().split()))",
                                        language: python, options: RunOptions(stdin: "Ada\neins zwei drei"))
        XCTAssertTrue(r.succeeded, r.stderr)
        XCTAssertTrue(r.stdout.contains("Hallo Ada"))
        XCTAssertTrue(r.stdout.hasSuffix("3\n"))
    }

    func testWithoutInputReadingEndsImmediately() async throws {
        try requirePython()
        let r = try await CodeRun().run(code: "import sys\nprint(repr(sys.stdin.read()))", language: python, options: RunOptions())
        XCTAssertEqual(r.stdout, "''\n")
    }

    func testInteractiveInput() async throws {
        try requirePython()
        let run = CodeRun()
        let task = Task { try await run.run(code: "a = input()\nb = input()\nprint(int(a) + int(b))", language: python,
                                            options: RunOptions(interactive: true, limits: ResourceLimits(timeout: 10))) }
        for _ in 0..<50 where !run.acceptsInput { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(run.acceptsInput)
        run.send("2\n")
        run.send("40\n")
        let r = try await task.value
        XCTAssertEqual(r.stdout, "42\n")
        XCTAssertFalse(run.acceptsInput)
    }

    func testHangingInputIsCancellable() async throws {
        try requirePython()
        let run = CodeRun()
        let task = Task { try await run.run(code: "input()", language: python, options: RunOptions(interactive: true)) }
        try await Task.sleep(for: .milliseconds(600))
        run.cancel()
        let r = try await task.value
        XCTAssertTrue(r.cancelled)
    }

    func testKernelInput() async throws {
        try requirePython()
        let k = try Kernel(language: KernelLanguages.python)
        defer { k.shutdown() }
        let r = await k.execute("x = input('Zahl: ')\nprint(int(x) * 2)", stdin: "21")
        XCTAssertTrue(r.succeeded, r.stderr)
        XCTAssertTrue(r.stdout.contains("42"))
        let eof = await k.execute("input()")
        XCTAssertFalse(eof.succeeded)
        XCTAssertTrue(eof.stderr.contains("EOFError"))
        // The session still works afterwards.
        let again = await k.execute("print(x)")
        XCTAssertTrue(again.stdout.contains("21"))
    }

    // MARK: Limits (#27, #32)

    func testOutputLimiterKeepsHeadAndTail() {
        var l = OutputLimiter(limit: 2048)
        l.append(Data(String(repeating: "a", count: 1500).utf8))
        l.append(Data(String(repeating: "b", count: 5000).utf8))
        l.append(Data("ENDE".utf8))
        XCTAssertTrue(l.text.hasPrefix(String(repeating: "a", count: 1024)))
        XCTAssertTrue(l.text.hasSuffix("ENDE"))
        XCTAssertTrue(l.text.contains("ausgelassen"))
        XCTAssertEqual(l.dropped, 1500 + 5000 + 4 - 2048)
        var small = OutputLimiter(limit: 2048)
        small.append(Data("kurz".utf8))
        XCTAssertEqual(small.text, "kurz")
    }

    func testOutputLimitInRun() async throws {
        try requirePython()
        let r = try await CodeRun().run(code: "for i in range(200000): print(i)", language: python,
                                        options: RunOptions(limits: ResourceLimits(maxOutputBytes: 10_000)))
        XCTAssertTrue(r.succeeded)
        XCTAssertLessThan(r.stdout.utf8.count, 12_000)
        XCTAssertTrue(r.stdout.hasPrefix("0\n1\n"))
        XCTAssertTrue(r.stdout.hasSuffix("199999\n"))
    }

    func testTimeout() async throws {
        try requirePython()
        let r = try await CodeRun().run(code: "import time\ntime.sleep(30)", language: python,
                                        options: RunOptions(limits: ResourceLimits(timeout: 1)))
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(r.duration, 5)
    }

    func testMemoryLimit() async throws {
        try requirePython()
        let r = try await CodeRun().run(code: "import time\nx = bytearray(400 * 1024 * 1024)\nfor i in range(0, len(x), 4096): x[i] = 1\ntime.sleep(10)",
                                        language: python, options: RunOptions(limits: ResourceLimits(timeout: 20, maxMemoryMB: 100)))
        XCTAssertTrue(r.memoryExceeded)
        XCTAssertFalse(r.succeeded)
        XCTAssertLessThan(r.duration, 8)
    }

    func testOrphansAreStopped() async throws {
        try requirePython()
        let marker = "folio-orphan-\(UUID().uuidString.prefix(8))"
        let code = "import subprocess, time\nsubprocess.Popen(['/bin/sleep', '60', '\(marker)'] if False else ['/bin/sh', '-c', 'exec -a \(marker) sleep 60'])\ntime.sleep(1.5)\nprint('fertig')"
        let r = try await CodeRun().run(code: code, language: python, options: RunOptions())
        XCTAssertTrue(r.succeeded, r.stderr)
        try await Task.sleep(for: .milliseconds(500))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", marker]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        let left = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(left, "", "the background process must be gone")
    }

    func testKernelOutputLimit() async throws {
        try requirePython()
        let k = try Kernel(language: KernelLanguages.python)
        defer { k.shutdown() }
        let r = await k.execute("for i in range(100000): print(i)", limits: ResourceLimits(maxOutputBytes: 4096))
        XCTAssertTrue(r.succeeded, r.stderr)
        XCTAssertLessThan(r.stdout.utf8.count, 5000)
        XCTAssertTrue(r.stdout.hasSuffix("99999\n"))
    }

    func testKernelUncooperativeTimeout() async throws {
        try requirePython()
        let k = try Kernel(language: KernelLanguages.python)
        defer { k.shutdown() }
        let r = await k.execute("import signal, time\nsignal.signal(signal.SIGINT, signal.SIG_IGN)\ntime.sleep(30)", timeout: 1)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(r.duration, 6)
    }

    func testLargeInputDoesNotPreventTimeout() async throws {
        try requirePython()
        let r = try await CodeRun().run(code: "import time\ntime.sleep(30)", language: python,
            options: RunOptions(stdin: String(repeating: "x", count: 1_000_000), limits: ResourceLimits(timeout: 1)))
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(r.duration, 6)
    }

    // MARK: Error markers (#30)

    func testPythonTraceback() {
        let out = """
        Traceback (most recent call last):
          File "/var/folders/x/folio-run-1/main.py", line 4, in <module>
            f()
          File "/var/folders/x/folio-run-1/main.py", line 2, in f
            return 1 / 0
        ZeroDivisionError: division by zero
        """
        XCTAssertEqual(DiagnosticParser.parse(out, fileName: "main.py"),
                       [CodeDiagnostic(line: 2, message: "ZeroDivisionError: division by zero")])
        let session = """
          File "<block>", line 3, in <module>
        NameError: name 'y' is not defined
        """
        XCTAssertEqual(DiagnosticParser.parse(session, fileName: "<block>").map(\.line), [3])
        let syntax = """
          File "/tmp/folio-run-2/main.py", line 5
            if x
                ^
        SyntaxError: expected ':'
        """
        XCTAssertEqual(DiagnosticParser.parse(syntax, fileName: "main.py"), [CodeDiagnostic(line: 5, message: "SyntaxError: expected ':'")])
    }

    func testCompilerDiagnostics() {
        let clang = """
        /tmp/folio-run-3/main.c:3:5: error: use of undeclared identifier 'y'
            y = 2;
            ^
        /tmp/folio-run-3/main.c:7:1: warning: non-void function does not return a value [-Wreturn-type]
        1 error generated.
        """
        XCTAssertEqual(DiagnosticParser.parse(clang, fileName: "main.c"), [
            CodeDiagnostic(line: 3, column: 5, message: "use of undeclared identifier 'y'"),
            CodeDiagnostic(line: 7, column: 1, message: "non-void function does not return a value [-Wreturn-type]", severity: .warning),
        ])
        let swift = "/tmp/x/main.swift:2:7: error: cannot find 'foo' in scope"
        XCTAssertEqual(DiagnosticParser.parse(swift, fileName: "main.swift").first?.line, 2)
        let go = "# command-line-arguments\n./main.go:6:2: undefined: fmtt"
        XCTAssertEqual(DiagnosticParser.parse(go, fileName: "main.go").first?.message, "undefined: fmtt")
        let rust = """
        error[E0425]: cannot find value `y` in this scope
         --> /tmp/r/main.rs:2:20
        """
        XCTAssertEqual(DiagnosticParser.parse(rust, fileName: "main.rs"),
                       [CodeDiagnostic(line: 2, column: 20, message: "cannot find value `y` in this scope")])
        let bash = "/tmp/b/main.sh: line 4: nope: command not found"
        XCTAssertEqual(DiagnosticParser.parse(bash, fileName: "main.sh"), [CodeDiagnostic(line: 4, message: "nope: command not found")])
        let node = """
        /tmp/n/main.js:3
        undefinedFunction();
        ^

        ReferenceError: undefinedFunction is not defined
            at Object.<anonymous> (/tmp/n/main.js:3:1)
        """
        XCTAssertEqual(DiagnosticParser.parse(node, fileName: "main.js").map(\.line), [3])
        XCTAssertTrue(DiagnosticParser.parse(node, fileName: "main.js").first?.message.contains("ReferenceError") == true)
        XCTAssertEqual(DiagnosticParser.parse("alles gut\n", fileName: "main.py"), [])
        XCTAssertEqual(DiagnosticParser.parse(clang, fileName: "main.c", lineCount: 5).map(\.line), [3], "lines past the end are dropped")
    }

    func testRealPythonErrorLine() async throws {
        try requirePython()
        let r = try await CodeRun().run(code: "a = 1\nb = a +\n", language: python)
        let d = DiagnosticParser.parse(r.stderr, fileName: r.fileName)
        XCTAssertEqual(d.first?.line, 2, r.stderr)
    }

    // MARK: Terminal (#23)

    func testTerminalTextCleaning() {
        XCTAssertEqual(TerminalText.clean("\u{1B}[1;32mgrün\u{1B}[0m normal\r\n"), "grün normal\n")
        XCTAssertEqual(TerminalText.clean("abc\u{08}\u{08}x"), "ax")
        XCTAssertEqual(TerminalText.clean("10%\r50%\r100%\n"), "100%\n")
        XCTAssertEqual(TerminalText.clean("\u{1B}]0;Titel\u{07}prompt$ "), "prompt$ ")
    }

    func testTerminalInterruptKeepsShellUsable() async throws {
        let out = LockedString()
        let term = try PseudoTerminal(command: ["/bin/sh"])
        defer { term.terminate() }
        term.onOutput = { out.append($0) }
        term.send("sleep 30\n")
        try await Task.sleep(for: .milliseconds(400))
        term.interrupt()
        try await Task.sleep(for: .milliseconds(200))
        term.send("echo after-\"interrupt\"\n")
        for _ in 0..<60 where !out.value.contains("after-interrupt") { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(out.value.contains("after-interrupt"), out.value)
        XCTAssertTrue(term.isRunning)
    }

    func testLoginShellTerminal() async throws {
        let out = LockedString()
        let term = try PseudoTerminal()
        defer { term.terminate() }
        term.onOutput = { out.append($0) }
        term.send("echo folio-\"42\"\n")
        for _ in 0..<80 where !out.value.contains("folio-42") { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(out.value.contains("folio-42"), out.value)
    }

    func testPseudoTerminalRunsInteractively() async throws {
        let out = LockedString()
        let term = try PseudoTerminal(command: ["/bin/sh"], directory: FileManager.default.temporaryDirectory)
        term.onOutput = { out.append($0) }
        term.send("echo folio-\"42\"\n")
        for _ in 0..<40 where !out.value.contains("folio-42") { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(out.value.contains("folio-42"))
        // A tty: programs see an interactive terminal.
        term.send("[ -t 0 ] && echo IS-TTY\n")
        for _ in 0..<40 where !out.value.contains("IS-TTY\r\n") && !out.value.contains("IS-TTY\n") { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(out.value.contains("IS-TTY"))
        term.send("exit\n")
        for _ in 0..<40 where term.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(term.isRunning)
    }
}

private final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var s = ""
    func append(_ t: String) { lock.lock(); s += t; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return s }
}

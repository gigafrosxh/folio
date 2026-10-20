import Foundation
import Darwin

/// Finds executables the way the user's shell would, even when the app was launched from Finder
/// (whose PATH is only /usr/bin:/bin:/usr/sbin:/sbin).
public final class InterpreterLocator: @unchecked Sendable {
    public static let shared = InterpreterLocator()

    private let lock = NSLock()
    private var cachedPath: [String]?

    public init() {}

    public var searchPath: [String] {
        lock.lock(); defer { lock.unlock() }
        if let p = cachedPath { return p }
        let p = Self.computeSearchPath()
        cachedPath = p
        return p
    }

    public func reset() {
        lock.lock(); cachedPath = nil; lock.unlock()
    }

    public func find(_ executable: String) -> String? {
        let executable = (executable as NSString).expandingTildeInPath
        if executable.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: executable) ? executable : nil }
        for dir in searchPath {
            let candidate = (dir as NSString).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["NO_COLOR"] = "1"
        if env["LANG"] == nil { env["LANG"] = "de_DE.UTF-8" }
        return env
    }

    private static func computeSearchPath() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs: [String] = []
        if let login = loginShellPath() { dirs += login.split(separator: ":").map(String.init) }
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                 "\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/go/bin", "\(home)/.bun/bin", "\(home)/.deno/bin",
                 "\(home)/miniforge3/bin", "\(home)/miniconda3/bin", "\(home)/anaconda3/bin", "\(home)/.pyenv/shims",
                 "\(home)/.rbenv/shims", "\(home)/.nvm/current/bin", "\(home)/.volta/bin", "/usr/local/go/bin",
                 "/Library/Frameworks/Python.framework/Versions/Current/bin"]
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Asks the user's login shell for its PATH (fish prints lists differently, so it gets its own command).
    private static func loginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let args: [String] = shell.hasSuffix("fish")
            ? ["-l", "-c", "string join : $PATH"]
            : ["-l", "-c", "printf %s \"$PATH\""]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = DispatchTime.now() + 3
        DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s.components(separatedBy: .newlines).last
    }
}

public struct RunResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var duration: TimeInterval
    public var command: String
    public var timedOut: Bool
    public var cancelled: Bool
    /// Local address of a server the program started, if it was recognized as one.
    public var serverURL: URL? = nil
    /// Stopped because the process tree used more memory than allowed.
    public var memoryExceeded = false
    /// The file the code was saved as ("main.py"), for finding error lines in the output.
    public var fileName = ""

    public var succeeded: Bool { exitCode == 0 && !timedOut && !cancelled && !memoryExceeded }

    public var combinedOutput: String {
        var parts: [String] = []
        if !stdout.isEmpty { parts.append(stdout) }
        if !stderr.isEmpty { parts.append(stderr) }
        return parts.joined(separator: stdout.hasSuffix("\n") || stdout.isEmpty ? "" : "\n")
    }
}

public enum CodeRunnerError: Error, LocalizedError {
    case notRunnable(String)
    case interpreterMissing(String, [String])

    public var errorDescription: String? {
        switch self {
        case .notRunnable(let lang): return "\(lang) kann nicht ausgeführt werden."
        case .interpreterMissing(let lang, let tried):
            return "Kein Interpreter für \(lang) gefunden (gesucht: \(tried.joined(separator: ", "))). In den Einstellungen kann ein eigener Befehl hinterlegt werden."
        }
    }
}

/// Everything about a run besides the code: input, environment and limits.
public struct RunOptions: Sendable {
    /// Text fed to the program's standard input.
    public var stdin: String?
    /// Keep standard input open for typing while the program runs (`CodeRun.send`).
    public var interactive = false
    public var workingDirectory: URL?
    /// Added to (and overriding) the normal environment.
    public var environment: [String: String] = [:]
    public var limits = ResourceLimits()

    public init(stdin: String? = nil, interactive: Bool = false, workingDirectory: URL? = nil,
                environment: [String: String] = [:], limits: ResourceLimits = ResourceLimits()) {
        self.stdin = stdin
        self.interactive = interactive
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.limits = limits
    }
}

/// Runs a snippet with an installed interpreter or compiler.
public final class CodeRun: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Process?
    private var isCancelled = false
    private var input: FileHandle?
    private var memoryHit = false

    /// Sends text to the running program's standard input (interactive runs).
    public func send(_ text: String) {
        lock.lock(); let h = input; lock.unlock()
        try? h?.write(contentsOf: Data(text.utf8))
    }

    /// Closes standard input (like ⌃D in a terminal), so programs reading until the end can finish.
    public func closeInput() {
        lock.lock(); let h = input; input = nil; lock.unlock()
        try? h?.close()
    }

    public var acceptsInput: Bool { lock.lock(); defer { lock.unlock() }; return input != nil }

    public init() {}

    public func cancel() {
        lock.lock()
        isCancelled = true
        let p = current
        lock.unlock()
        if let p, p.isRunning { ServerDetector.terminateTree(p.processIdentifier) }
    }

    /// Resolves the commands that would run `language`; `override` is a user-supplied command line
    /// such as `/opt/homebrew/bin/python3.12 {file}`.
    public static func plan(for language: LanguageSpec, override: String? = nil,
                            locator: InterpreterLocator = .shared) throws -> [[String]] {
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            let steps = override.components(separatedBy: "&&").map { step in
                step.split(separator: " ").map(String.init)
            }.filter { !$0.isEmpty }
            var cmd = steps
            if !override.contains("{file}"), !cmd.isEmpty { cmd[cmd.count - 1].append("{file}") }
            return try cmd.map { step in
                guard let resolved = resolve(step, locator: locator) else {
                    throw CodeRunnerError.interpreterMissing(language.name, [step[0]])
                }
                return resolved
            }
        }
        guard language.isRunnable else { throw CodeRunnerError.notRunnable(language.name) }
        for plan in language.runPlans {
            let resolved = plan.compactMap { resolve($0, locator: locator) }
            if resolved.count == plan.count { return resolved }
        }
        throw CodeRunnerError.interpreterMissing(language.name, language.runPlans.compactMap { $0.first?.first })
    }

    private static func resolve(_ command: [String], locator: InterpreterLocator) -> [String]? {
        guard let exe = command.first else { return nil }
        if exe.hasPrefix("{") { return command }
        guard let path = locator.find(exe) else { return nil }
        return [path] + command.dropFirst()
    }

    /// Human-readable description of what would run, e.g. "python3" or "clang → ./a.out".
    public static func describe(_ plan: [[String]]) -> String {
        plan.map { ($0.first.map { ($0 as NSString).lastPathComponent } ?? "") }
            .map { $0 == "{out}" ? "Programm" : $0 }
            .joined(separator: " → ")
    }

    public func run(code: String, language: LanguageSpec, override: String? = nil, timeout: TimeInterval = 30,
                    locator: InterpreterLocator = .shared,
                    onOutput: (@Sendable (String) -> Void)? = nil,
                    onServer: (@Sendable (URL) -> Void)? = nil) async throws -> RunResult {
        try await run(code: code, language: language, override: override,
                      options: RunOptions(limits: ResourceLimits(timeout: timeout)), locator: locator, onOutput: onOutput, onServer: onServer)
    }

    public func run(code: String, language: LanguageSpec, override: String? = nil, options: RunOptions,
                    locator: InterpreterLocator = .shared,
                    onOutput: (@Sendable (String) -> Void)? = nil,
                    onServer: (@Sendable (URL) -> Void)? = nil) async throws -> RunResult {
        let timeout = options.limits.timeout
        let plan = try Self.plan(for: language, override: override, locator: locator)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("main.\(language.fileExtension)")
        try code.write(to: file, atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent("main.out").path

        let start = Date()
        var stdout = "", stderr = ""
        var exitCode: Int32 = 0
        var timedOut = false
        for (index, step) in plan.enumerated() {
            let args = step.map {
                $0.replacingOccurrences(of: "{file}", with: file.path)
                    .replacingOccurrences(of: "{out}", with: out)
                    .replacingOccurrences(of: "{dir}", with: dir.path)
            }
            // Only the last step (the program itself) can be a server; compile steps keep the timeout.
            let isLast = index == plan.count - 1
            var env = locator.environment
            for (k, v) in options.environment { env[k] = v }
            // Compile steps run next to the source; the program itself in the chosen working directory.
            let cwd = isLast ? (options.workingDirectory ?? dir) : dir
            let r = try await runProcess(args, in: cwd, environment: env, timeout: timeout,
                                         stdin: isLast ? options.stdin : nil, interactive: isLast && options.interactive,
                                         limits: options.limits,
                                         onOutput: onOutput, onServer: isLast ? onServer : nil, detectServer: isLast)
            stdout += r.0
            stderr += r.1
            exitCode = r.2
            timedOut = r.3
            if exitCode != 0 || timedOut || cancelledNow { break }
        }
        var result = RunResult(stdout: stdout, stderr: stderr, exitCode: exitCode, duration: Date().timeIntervalSince(start),
                               command: Self.describe(plan), timedOut: timedOut, cancelled: cancelledNow, serverURL: serverURL)
        result.memoryExceeded = memoryExceededNow
        result.fileName = file.lastPathComponent
        return result
    }

    private var cancelledNow: Bool { lock.lock(); defer { lock.unlock() }; return isCancelled }
    private var memoryExceededNow: Bool { lock.lock(); defer { lock.unlock() }; return memoryHit }

    /// Set once the running program was recognized as a server.
    public var serverURL: URL? { lock.lock(); defer { lock.unlock() }; return detectedServer }
    private var detectedServer: URL?

    private func markServer(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if detectedServer != nil { return false }
        detectedServer = url
        return true
    }

    private func runProcess(_ args: [String], in dir: URL, environment: [String: String], timeout: TimeInterval,
                            stdin: String? = nil, interactive: Bool = false, limits: ResourceLimits = ResourceLimits(),
                            onOutput: (@Sendable (String) -> Void)?, onServer: (@Sendable (URL) -> Void)?,
                            detectServer: Bool) async throws -> (String, String, Int32, Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        p.currentDirectoryURL = dir
        p.environment = environment
        var inPipe: Pipe?
        if stdin != nil || interactive {
            let pipe = Pipe()
            p.standardInput = pipe
            inPipe = pipe
        } else {
            p.standardInput = FileHandle.nullDevice
        }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let outBuffer = LockedData(limit: limits.maxOutputBytes), errBuffer = LockedData(limit: limits.maxOutputBytes / 2)
        let seen = LockedPIDs()
        let found: (URL) -> Void = { [weak self] url in
            guard let self, self.markServer(url) else { return }
            onServer?(url)
        }
        let handle: (FileHandle, LockedData) -> Void = { h, buffer in
            let data = h.availableData
            guard !data.isEmpty else { return }
            buffer.append(data)
            let text = String(decoding: data, as: UTF8.self)
            onOutput?(text)
            if detectServer, let url = ServerDetector.url(inOutput: text) { found(url) }
        }
        outPipe.fileHandleForReading.readabilityHandler = { handle($0, outBuffer) }
        errPipe.fileHandleForReading.readabilityHandler = { handle($0, errBuffer) }

        let timedOut = LockedFlag()
        return try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { [weak self] proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                self?.closeInput()
                // Background processes the program left behind would otherwise run on forever.
                if limits.killOrphans, self?.serverURL == nil {
                    for pid in seen.all where kill(pid, 0) == 0 { kill(pid, SIGTERM) }
                }
                outBuffer.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                errBuffer.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: (outBuffer.string, errBuffer.string, proc.terminationStatus, timedOut.value))
            }
            do {
                lock.lock(); current = p; let cancelled = isCancelled; lock.unlock()
                if cancelled { cont.resume(returning: ("", "", -1, false)); return }
                try p.run()
                if let inPipe {
                    let h = inPipe.fileHandleForWriting
                    _ = fcntl(h.fileDescriptor, F_SETNOSIGPIPE, 1)
                    if interactive { lock.lock(); input = h; lock.unlock() }
                    // A large input must not block the caller or delay installing the timeout.
                    DispatchQueue.global().async {
                        if let stdin, !stdin.isEmpty { try? h.write(contentsOf: Data((stdin.hasSuffix("\n") ? stdin : stdin + "\n").utf8)) }
                        if !interactive { try? h.close() }
                    }
                }
                let pid = p.processIdentifier
                // Watch the process tree: remember children (to clean up orphans) and enforce the memory limit.
                DispatchQueue.global().async { [weak self] in
                    while p.isRunning {
                        let tree = ServerDetector.descendants(of: pid)
                        seen.add(tree)
                        if limits.maxMemoryMB > 0, ServerDetector.residentMemoryMB(of: [pid] + tree) > limits.maxMemoryMB {
                            self?.lock.lock(); self?.memoryHit = true; self?.lock.unlock()
                            ServerDetector.terminateTree(pid)
                            break
                        }
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                }
                // Servers often print nothing; also look for listening sockets of the process tree.
                if detectServer {
                    DispatchQueue.global().async { [weak self] in
                        while p.isRunning, self?.serverURL == nil {
                            if let port = ServerDetector.listeningPort(ofProcessTree: pid) {
                                found(URL(string: "http://localhost:\(port)")!)
                                break
                            }
                            Thread.sleep(forTimeInterval: 1)
                        }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    // A recognized server keeps running until it is stopped.
                    guard p.isRunning, self?.serverURL == nil else { return }
                    timedOut.set()
                    ServerDetector.terminateTree(pid)
                }
            } catch {
                p.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
    }
}

/// Recognizes programs that serve HTTP and manages their process trees.
public enum ServerDetector {
    private static let urlRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:https?://)?(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|(?:\d{1,3}\.){3}\d{1,3}|[a-z0-9-]+\.local):(\d{2,5})\b"#)
    private static let portRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:listening|serving|running|started|server)\b[^\n]{0,60}?\bport\s*:?\s*(\d{2,5})\b"#)

    /// A local URL announced in program output ("Running on http://127.0.0.1:5000", "Listening on port 3000").
    public static func url(inOutput text: String) -> URL? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let m = urlRegex.firstMatch(in: text, range: range) {
            var host = ns.substring(with: m.range(at: 1)).lowercased()
            if host == "0.0.0.0" || host.hasPrefix("[") { host = "localhost" }
            return URL(string: "http://\(host):\(ns.substring(with: m.range(at: 2)))")
        }
        if let m = portRegex.firstMatch(in: text, range: range) {
            return URL(string: "http://localhost:\(ns.substring(with: m.range(at: 1)))")
        }
        return nil
    }

    /// All descendants of `pid` (children, grandchildren …).
    public static func descendants(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue = [pid]
        while let next = queue.popLast() {
            let children = run("/usr/bin/pgrep", ["-P", "\(next)"]).split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
            result += children
            queue += children
        }
        return result
    }

    /// First TCP port the process or any of its descendants listens on.
    public static func listeningPort(ofProcessTree pid: pid_t) -> Int? {
        let pids = ([pid] + descendants(of: pid)).map(String.init).joined(separator: ",")
        let out = run("/usr/sbin/lsof", ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", pids])
        for line in out.split(whereSeparator: \.isNewline).dropFirst() {
            if let r = line.range(of: #":(\d+) \(LISTEN\)"#, options: .regularExpression) {
                return Int(line[r].dropFirst().split(separator: " ").first ?? "")
            }
        }
        return nil
    }

    /// Resident memory of the given processes together, in megabytes.
    public static func residentMemoryMB(of pids: [pid_t]) -> Int {
        guard !pids.isEmpty else { return 0 }
        let out = run("/bin/ps", ["-o", "rss=", "-p", pids.map(String.init).joined(separator: ",")])
        let kb = out.split(whereSeparator: \.isNewline).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.reduce(0, +)
        return kb / 1024
    }

    /// Stops a process and everything it started (dev servers often spawn workers).
    public static func terminateTree(_ pid: pid_t) {
        let all = descendants(of: pid) + [pid]
        for p in all { kill(p, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            for p in all where kill(p, 0) == 0 { kill(p, SIGKILL) }
        }
    }

    private static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var limiter: OutputLimiter

    init(limit: Int = 2_000_000) { limiter = OutputLimiter(limit: limit) }

    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        limiter.append(d)
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return limiter.text
    }
}

private final class LockedPIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var pids = Set<pid_t>()
    func add(_ p: [pid_t]) { lock.lock(); pids.formUnion(p); lock.unlock() }
    var all: [pid_t] { lock.lock(); defer { lock.unlock() }; return Array(pids) }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

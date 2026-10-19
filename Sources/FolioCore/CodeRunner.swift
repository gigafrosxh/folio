import Foundation

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

    public var succeeded: Bool { exitCode == 0 && !timedOut && !cancelled }

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

/// Runs a snippet with an installed interpreter or compiler.
public final class CodeRun: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Process?
    private var isCancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        isCancelled = true
        let p = current
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
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
                    locator: InterpreterLocator = .shared) async throws -> RunResult {
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
        for step in plan {
            let args = step.map {
                $0.replacingOccurrences(of: "{file}", with: file.path)
                    .replacingOccurrences(of: "{out}", with: out)
                    .replacingOccurrences(of: "{dir}", with: dir.path)
            }
            let r = try await runProcess(args, in: dir, environment: locator.environment, timeout: timeout)
            stdout += r.0
            stderr += r.1
            exitCode = r.2
            timedOut = r.3
            if exitCode != 0 || timedOut || cancelledNow { break }
        }
        return RunResult(stdout: stdout, stderr: stderr, exitCode: exitCode, duration: Date().timeIntervalSince(start),
                         command: Self.describe(plan), timedOut: timedOut, cancelled: cancelledNow)
    }

    private var cancelledNow: Bool { lock.lock(); defer { lock.unlock() }; return isCancelled }

    private func runProcess(_ args: [String], in dir: URL, environment: [String: String],
                            timeout: TimeInterval) async throws -> (String, String, Int32, Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        p.currentDirectoryURL = dir
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let outBuffer = LockedData(), errBuffer = LockedData()
        outPipe.fileHandleForReading.readabilityHandler = { h in outBuffer.append(h.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { h in errBuffer.append(h.availableData) }

        let timedOut = LockedFlag()
        return try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                outBuffer.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                errBuffer.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: (outBuffer.string, errBuffer.string, proc.terminationStatus, timedOut.value))
            }
            do {
                lock.lock(); current = p; let cancelled = isCancelled; lock.unlock()
                if cancelled { cont.resume(returning: ("", "", -1, false)); return }
                try p.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if p.isRunning { timedOut.set(); p.terminate() }
                }
            } catch {
                p.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 2_000_000

    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count < limit { data.append(d.prefix(limit - data.count)) }
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

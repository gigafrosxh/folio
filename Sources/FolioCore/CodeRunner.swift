import Foundation
import Darwin

#if os(macOS)
    /// Finds executables the way the user's shell would, even when the app was launched from Finder
    /// (whose PATH is only /usr/bin:/bin:/usr/sbin:/sbin).
    public final class InterpreterLocator: @unchecked Sendable {
        public static let shared = InterpreterLocator()

        private let lock = NSLock()
        private var cachedPath: [String]?

        public init() {}

        public var searchPath: [String] {
            lock.lock()
            defer { lock.unlock() }
            if let p = cachedPath { return p }
            let p = Self.computeSearchPath()
            cachedPath = p
            return p
        }

        public func reset() {
            lock.lock()
            cachedPath = nil
            lock.unlock()
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
            dirs += [
                "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                "\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/go/bin", "\(home)/.bun/bin", "\(home)/.deno/bin",
                "\(home)/miniforge3/bin", "\(home)/miniconda3/bin", "\(home)/anaconda3/bin", "\(home)/.pyenv/shims",
                "\(home)/.rbenv/shims", "\(home)/.nvm/current/bin", "\(home)/.volta/bin", "/usr/local/go/bin",
                "/Library/Frameworks/Python.framework/Versions/Current/bin"
            ]
            var seen = Set<String>()
            return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
        }

        /// Asks the user's login shell for its PATH (fish prints lists differently, so it gets its own command).
        private static func loginShellPath() -> String? {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let args: [String] =
                shell.hasSuffix("fish")
                ? ["-l", "-c", "string join : $PATH"]
                : ["-l", "-c", "printf %s \"$PATH\""]
            // A hard limit: the shell and everything its startup files start are stopped after 3 s, and the pipe is
            // read without waiting for helpers that keep it open (#299).
            let out = Pipe()
            let null = open("/dev/null", O_RDWR)
            defer { close(null) }
            guard
                let p = try? GroupProcess(
                    executable: shell, arguments: args, directory: FileManager.default.homeDirectoryForCurrentUser,
                    environment: ProcessInfo.processInfo.environment, stdin: null, stdout: out.fileHandleForWriting.fileDescriptor, stderr: null)
            else { return nil }
            try? out.fileHandleForWriting.close()
            let done = DispatchSemaphore(value: 0)
            p.onExit { _ in done.signal() }
            if done.wait(timeout: .now() + 3) == .timedOut { p.signalGroup(SIGKILL) }
            let data = drainBounded(out.fileHandleForReading, timeout: 0.5)
            p.signalGroup(SIGKILL)
            let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s.components(separatedBy: .newlines).last
        }
    }

#endif

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

    public init(
        stdin: String? = nil, interactive: Bool = false, workingDirectory: URL? = nil,
        environment: [String: String] = [:], limits: ResourceLimits = ResourceLimits()
    ) {
        self.stdin = stdin
        self.interactive = interactive
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.limits = limits
    }
}

#if os(macOS)
    /// Runs a snippet with an installed interpreter or compiler.
    public final class CodeRun: @unchecked Sendable {
        private let lock = NSLock()
        private var current: GroupProcess?
        private var isCancelled = false
        private var input: FileHandle?
        private var memoryHit = false

        /// Sends text to the running program's standard input (interactive runs).
        public func send(_ text: String) {
            lock.lock()
            let h = input
            lock.unlock()
            try? h?.write(contentsOf: Data(text.utf8))
        }

        /// Closes standard input (like ⌃D in a terminal), so programs reading until the end can finish.
        public func closeInput() {
            lock.lock()
            let h = input
            input = nil
            lock.unlock()
            try? h?.close()
        }

        public var acceptsInput: Bool {
            lock.lock()
            defer { lock.unlock() }
            return input != nil
        }

        public init() {}

        public func cancel() {
            lock.lock()
            isCancelled = true
            let p = current
            lock.unlock()
            if let p { Self.stop(p) }
        }

        /// Stops a run's whole process group: SIGTERM now, SIGKILL after 1.5 s for whatever is still there.
        static func stop(_ p: GroupProcess) {
            p.signalGroup(SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { if p.groupIsAlive { p.signalGroup(SIGKILL) } }
        }

        /// Resolves the commands that would run `language`; `override` is a user-supplied command line
        /// such as `/opt/homebrew/bin/python3.12 {file}`.
        public static func plan(
            for language: LanguageSpec, override: String? = nil,
            locator: InterpreterLocator = .shared
        ) throws -> [[String]] {
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

        public func run(
            code: String, language: LanguageSpec, override: String? = nil, timeout: TimeInterval = 30,
            locator: InterpreterLocator = .shared,
            onOutput: (@Sendable (String) -> Void)? = nil,
            onServer: (@Sendable (URL) -> Void)? = nil
        ) async throws -> RunResult {
            try await run(
                code: code, language: language, override: override,
                options: RunOptions(limits: ResourceLimits(timeout: timeout)), locator: locator, onOutput: onOutput, onServer: onServer)
        }

        public func run(
            code: String, language: LanguageSpec, override: String? = nil, options: RunOptions,
            locator: InterpreterLocator = .shared,
            onOutput: (@Sendable (String) -> Void)? = nil,
            onServer: (@Sendable (URL) -> Void)? = nil
        ) async throws -> RunResult {
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
                let r = try await runProcess(
                    args, in: cwd, environment: env, timeout: timeout,
                    stdin: isLast ? options.stdin : nil, interactive: isLast && options.interactive,
                    limits: options.limits,
                    onOutput: onOutput, onServer: isLast ? onServer : nil, detectServer: isLast)
                stdout += r.0
                stderr += r.1
                exitCode = r.2
                timedOut = r.3
                if exitCode != 0 || timedOut || cancelledNow { break }
            }
            var result = RunResult(
                stdout: stdout, stderr: stderr, exitCode: exitCode, duration: Date().timeIntervalSince(start),
                command: Self.describe(plan), timedOut: timedOut, cancelled: cancelledNow, serverURL: serverURL)
            result.memoryExceeded = memoryExceededNow
            result.fileName = file.lastPathComponent
            return result
        }

        private var cancelledNow: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isCancelled
        }
        private var memoryExceededNow: Bool {
            lock.lock()
            defer { lock.unlock() }
            return memoryHit
        }

        /// Set once the running program was recognized as a server.
        public var serverURL: URL? {
            lock.lock()
            defer { lock.unlock() }
            return detectedServer
        }
        private var detectedServer: URL?

        private func markServer(_ url: URL) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if detectedServer != nil { return false }
            detectedServer = url
            return true
        }

        /// What one process of a run needs besides its arguments, directory and environment (#142).
        fileprivate struct ProcessJob {
            let timeout: TimeInterval
            let stdin: String?
            let interactive: Bool
            let limits: ResourceLimits
            let detectServer: Bool
            let found: (URL) -> Void
            let seen = LockedPIDs()
            let timedOut = LockedFlag()
        }

        private typealias ProcessOutcome = (String, String, Int32, Bool)

        private func runProcess(
            _ args: [String], in dir: URL, environment: [String: String], timeout: TimeInterval,
            stdin: String? = nil, interactive: Bool = false, limits: ResourceLimits = ResourceLimits(),
            onOutput: (@Sendable (String) -> Void)?, onServer: (@Sendable (URL) -> Void)?,
            detectServer: Bool
        ) async throws -> ProcessOutcome {
            let inPipe = stdin != nil || interactive ? Pipe() : nil
            let capture = OutputCapture(limits: limits)
            let job = ProcessJob(
                timeout: timeout, stdin: stdin, interactive: interactive, limits: limits, detectServer: detectServer,
                found: { [weak self] url in
                    guard let self, self.markServer(url) else { return }
                    onServer?(url)
                })
            return try await withCheckedThrowingContinuation { cont in
                do {
                    try launch(args, in: dir, environment: environment, inPipe: inPipe, capture: capture, job: job, onOutput: onOutput, cont: cont)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        /// Starting and cancelling share the lock: a cancel either finds the process or stops the launch (#290).
        private func launch(
            _ args: [String], in dir: URL, environment: [String: String], inPipe: Pipe?, capture: OutputCapture, job: ProcessJob,
            onOutput: (@Sendable (String) -> Void)?, cont: CheckedContinuation<ProcessOutcome, Error>
        ) throws {
            let null = open("/dev/null", O_RDONLY)
            defer { close(null) }
            lock.lock()
            if isCancelled {
                lock.unlock()
                cont.resume(returning: ("", "", -1, false))
                return
            }
            let p: GroupProcess
            do {
                p = try GroupProcess(
                    executable: args[0], arguments: Array(args.dropFirst()), directory: dir, environment: environment,
                    stdin: inPipe?.fileHandleForReading.fileDescriptor ?? null,
                    stdout: capture.outPipe.fileHandleForWriting.fileDescriptor, stderr: capture.errPipe.fileHandleForWriting.fileDescriptor)
            } catch {
                lock.unlock()
                throw error
            }
            current = p
            lock.unlock()
            // The child has its own copies; ours must close, or the pipes never report their end.
            capture.closeWriteEnds()
            try? inPipe?.fileHandleForReading.close()
            capture.startReading(onOutput: onOutput, serverFound: job.detectServer ? { [weak self] url in self?.confirmServer(url, p: p, job: job) } : nil)
            p.onExit { [weak self] status in self.finishProcess(p, status: status, capture: capture, job: job, cont: cont) }
            if let inPipe { feedInput(inPipe.fileHandleForWriting, job: job) }
            watchProcessTree(p, job: job)
            if job.detectServer { watchForListeningPort(p, job: job) }
            armTimeout(p, job: job)
        }

        /// A local address in the output only counts once the program really listens on a port; a program that
        /// merely prints "localhost:8080" keeps its time limit (#291).
        private func confirmServer(_ url: URL, p: GroupProcess, job: ProcessJob) {
            DispatchQueue.global().async {
                for _ in 0..<6 where p.isRunning {
                    if ServerDetector.listeningPort(ofProcessTree: p.pid) != nil {
                        job.found(url)
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }

        /// A large input must not block the caller or delay installing the timeout.
        private func feedInput(_ handle: FileHandle, job: ProcessJob) {
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            if job.interactive {
                lock.lock()
                input = handle
                lock.unlock()
            }
            DispatchQueue.global().async {
                if let stdin = job.stdin, !stdin.isEmpty { try? handle.write(contentsOf: Data((stdin.hasSuffix("\n") ? stdin : stdin + "\n").utf8)) }
                if !job.interactive { try? handle.close() }
            }
        }

        /// Remembers child processes (also ones that left the group) and enforces the memory limit. The limit is
        /// checked by polling every 0.25 s, so it is a soft limit: a program can briefly go above it (#300).
        private func watchProcessTree(_ p: GroupProcess, job: ProcessJob) {
            let pid = p.pid
            DispatchQueue.global().async { [weak self] in
                while p.isRunning {
                    let tree = ServerDetector.descendants(of: pid)
                    job.seen.add(tree.compactMap(ProcessIdentity.of))
                    if job.limits.maxMemoryMB > 0, ServerDetector.residentMemoryMB(of: [pid] + tree) > job.limits.maxMemoryMB {
                        self?.lock.lock()
                        self?.memoryHit = true
                        self?.lock.unlock()
                        CodeRun.stop(p)
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }
        }

        /// Servers often print nothing; also look for listening sockets of the process tree.
        private func watchForListeningPort(_ p: GroupProcess, job: ProcessJob) {
            let pid = p.pid
            DispatchQueue.global().async { [weak self] in
                while p.isRunning, self?.serverURL == nil {
                    if let port = ServerDetector.listeningPort(ofProcessTree: pid) {
                        job.found(URL(string: "http://localhost:\(port)")!)
                        break
                    }
                    Thread.sleep(forTimeInterval: 1)
                }
            }
        }

        private func armTimeout(_ p: GroupProcess, job: ProcessJob) {
            DispatchQueue.global().asyncAfter(deadline: .now() + job.timeout) { [weak self] in
                // A recognized server keeps running until it is stopped.
                guard p.isRunning, self?.serverURL == nil else { return }
                job.timedOut.set()
                CodeRun.stop(p)
            }
        }
    }

    private extension Optional where Wrapped == CodeRun {
        func finishProcess(
            _ p: GroupProcess, status: Int32, capture: OutputCapture, job: CodeRun.ProcessJob, cont: CheckedContinuation<(String, String, Int32, Bool), Error>
        ) {
            capture.stopReading()
            self?.closeInput()
            // Background processes the program left behind would otherwise run on forever: the whole group, and
            // children seen earlier that left it, if they are still the same processes (#288, #289).
            if job.limits.killOrphans, self?.serverURL == nil {
                p.signalGroup(SIGTERM)
                for orphan in job.seen.all { orphan.signal(SIGTERM) }
            }
            // Never waits long for helpers that keep the pipes open (#287).
            capture.drain()
            cont.resume(returning: (capture.out.string, capture.err.string, status, job.timedOut.value))
        }
    }

    /// Collects a process's stdout and stderr, streaming new output as it arrives: decoded across chunk borders (#294)
    /// and only up to an output budget, after which the run goes on without live output (#295).
    final class OutputCapture: @unchecked Sendable {
        let out: LockedData
        let err: LockedData
        let outPipe = Pipe()
        let errPipe = Pipe()
        private let lock = NSLock()
        private var streams = [UTF8Stream(), UTF8Stream()]
        private var streamed = 0
        private let streamBudget: Int

        init(limits: ResourceLimits) {
            out = LockedData(limit: limits.maxOutputBytes)
            err = LockedData(limit: limits.maxOutputBytes / 2)
            streamBudget = max(limits.maxOutputBytes * 2, 64_000)
        }

        static let budgetNote = "\n… Weitere Ausgabe wird nicht mehr live angezeigt (Grenze erreicht); Anfang und Ende stehen im Ergebnis.\n"

        func closeWriteEnds() {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
        }

        /// Text to show live for a chunk of stream `index`, nil when nothing (more) is to be shown.
        func live(_ data: Data, stream index: Int) -> String? {
            lock.lock()
            defer { lock.unlock() }
            let text = streams[index].decode(data)
            guard streamed <= streamBudget, !text.isEmpty else { return nil }
            streamed += data.count
            return streamed > streamBudget ? text + Self.budgetNote : text
        }

        func startReading(onOutput: (@Sendable (String) -> Void)?, serverFound: ((URL) -> Void)?) {
            let handle: (FileHandle, LockedData, Int) -> Void = { [weak self] h, buffer, index in
                let data = h.availableData
                guard !data.isEmpty, let self else { return }
                buffer.append(data)
                guard let text = self.live(data, stream: index) else { return }
                onOutput?(text)
                if let serverFound, let url = ServerDetector.url(inOutput: text) { serverFound(url) }
            }
            let out = self.out, err = self.err
            outPipe.fileHandleForReading.readabilityHandler = { handle($0, out, 0) }
            errPipe.fileHandleForReading.readabilityHandler = { handle($0, err, 1) }
        }

        func stopReading() {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
        }

        func drain() {
            out.append(drainBounded(outPipe.fileHandleForReading))
            err.append(drainBounded(errPipe.fileHandleForReading, timeout: 0.2))
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
        /// Memory of the processes in MB as Activity Monitor counts it: the physical footprint, which includes
        /// compressed and swapped pages. Resident memory alone let compressible data slip past the limit (#198).
        /// Processes that cannot be asked fall back to their resident size.
        public static func residentMemoryMB(of pids: [pid_t]) -> Int {
            guard !pids.isEmpty else { return 0 }
            var bytes: UInt64 = 0
            var fallback: [pid_t] = []
            for pid in pids {
                if let footprint = physicalFootprint(of: pid) { bytes += footprint } else { fallback.append(pid) }
            }
            var mb = Int(bytes / 1_048_576)
            if !fallback.isEmpty {
                let out = run("/bin/ps", ["-o", "rss=", "-p", fallback.map(String.init).joined(separator: ",")])
                mb += out.split(whereSeparator: \.isNewline).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.reduce(0, +) / 1024
            }
            return mb
        }

        /// `phys_footprint` of one process, nil when it cannot be read (gone, or another user's).
        public static func physicalFootprint(of pid: pid_t) -> UInt64? {
            var info = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            return result == 0 ? info.ri_phys_footprint : nil
        }

        /// Stops a process and everything it started (dev servers often spawn workers). The later SIGKILL only goes to
        /// processes that are still the same ones, never to a program that got a reused pid (#288).
        public static func terminateTree(_ pid: pid_t) {
            let all = (descendants(of: pid) + [pid]).compactMap(ProcessIdentity.of)
            for p in all { p.signal(SIGTERM) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                for p in all { p.signal(SIGKILL) }
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

    final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var limiter: OutputLimiter

        init(limit: Int = 2_000_000) { limiter = OutputLimiter(limit: limit) }

        func append(_ d: Data) {
            lock.lock()
            defer { lock.unlock() }
            limiter.append(d)
        }

        var string: String {
            lock.lock()
            defer { lock.unlock() }
            return limiter.text
        }
    }

    final class LockedPIDs: @unchecked Sendable {
        private let lock = NSLock()
        private var pids = Set<ProcessIdentity>()
        func add(_ p: [ProcessIdentity]) {
            lock.lock()
            pids.formUnion(p)
            lock.unlock()
        }
        var all: [ProcessIdentity] {
            lock.lock()
            defer { lock.unlock() }
            return Array(pids)
        }
    }

    final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() {
            lock.lock()
            flag = true
            lock.unlock()
        }
        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return flag
        }
    }
#endif

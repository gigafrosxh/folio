import Foundation
import Darwin

/// How to start a persistent interpreter ("kernel") for a language and talk to it.
///
/// Protocol: the host writes one JSON object per line to the kernel's stdin:
///   {"id": "<id>", "op": "exec", "code": "<source>"}      run code in the shared namespace
///   {"id": "<id>", "op": "complete", "receiver": "<expr or empty>"}   list names (no side effects)
/// After handling a message the kernel prints the marker line `\u{1E}<id>:<status>` on stdout and on stderr
/// (status "ok" or "error"; for "complete" the stdout line before the marker is a JSON array of names).
public struct KernelLanguage: Sendable {
    public var id: String
    /// Executable name (resolved via InterpreterLocator) and its arguments; `{script}` is replaced by the
    /// kernel source written to a temporary file.
    public var command: [String]
    public var fileExtension: String
    public var script: String
    public var supportsCompletion: Bool

    public init(id: String, command: [String], fileExtension: String, supportsCompletion: Bool, script: String) {
        self.id = id
        self.command = command
        self.fileExtension = fileExtension
        self.script = script
        self.supportsCompletion = supportsCompletion
    }
}

public enum KernelLanguages {
    /// All languages with a shared session. Extra languages are registered in `KernelLanguages+More.swift`.
    public static var all: [KernelLanguage] { [python] + more }

    public static func spec(for language: String) -> KernelLanguage? { all.first { $0.id == language } }

    public static let python = KernelLanguage(
        id: "python", command: ["python3", "-u", "{script}"], fileExtension: "py", supportsCompletion: true,
        script: #"""
import ast, io, json, sys, traceback, builtins
ns = {"__name__": "__main__", "__builtins__": builtins}
MARK = "\x1e"

def run(code):
    tree = ast.parse(code, "<block>", "exec")
    last = None
    if tree.body and isinstance(tree.body[-1], ast.Expr):
        last = ast.Expression(tree.body.pop().value)
    exec(compile(tree, "<block>", "exec"), ns)
    if last is not None:
        value = eval(compile(last, "<block>", "eval"), ns)
        if value is not None:
            print(repr(value))

def names(receiver):
    if not receiver:
        return sorted(set(k for k in ns if not k.startswith("__")) | set(dir(builtins)))
    obj = None
    parts = receiver.split(".")
    if not all(p.isidentifier() for p in parts):
        return []
    obj = ns.get(parts[0], getattr(builtins, parts[0], None))
    for p in parts[1:]:
        obj = getattr(obj, p, None)
    if obj is None and parts[0] not in ns:
        return []
    return [n for n in dir(obj) if not n.startswith("__")]

for line in sys.stdin:
    try:
        msg = json.loads(line)
    except Exception:
        continue
    status = "ok"
    try:
        if msg.get("op") == "complete":
            print(json.dumps(names(msg.get("receiver") or "")))
        else:
            # Input for input()/sys.stdin comes with the message; reading past it raises EOFError.
            real_stdin = sys.stdin
            sys.stdin = io.StringIO(msg.get("stdin", ""))
            try:
                run(msg.get("code", ""))
            finally:
                sys.stdin = real_stdin
    except KeyboardInterrupt:
        status = "error"
        print("KeyboardInterrupt", file=sys.stderr)
    except SystemExit:
        pass
    except BaseException:
        status = "error"
        etype, value, tb = sys.exc_info()
        frames = [f for f in traceback.extract_tb(tb) if f.filename == "<block>"]
        print("".join(traceback.format_list(frames) + traceback.format_exception_only(etype, value)), end="", file=sys.stderr)
    sys.stdout.flush(); sys.stderr.flush()
    print(MARK + msg.get("id", "") + ":" + status, flush=True)
    print(MARK + msg.get("id", "") + ":" + status, file=sys.stderr, flush=True)
"""#)
}

/// A running interpreter that keeps variables between runs.
public final class Kernel: @unchecked Sendable {
    public let language: KernelLanguage
    private let process = Process()
    private let input: FileHandle
    private let scriptURL: URL
    private let lock = NSLock()
    private var outBuffer = Data()
    private var errBuffer = Data()
    private var current: (id: String, onOutput: (@Sendable (String) -> Void)?, outDone: Bool, errDone: Bool,
                          stdout: OutputLimiter, stderr: OutputLimiter, status: String, finish: (() -> Void)?)? = nil
    private var queue: [() -> Void] = []
    private var busy = false

    public var isAlive: Bool { process.isRunning }
    public var pid: pid_t { process.processIdentifier }

    /// `executable` replaces the language's interpreter (a per-note setting); `directory` and
    /// `environment` set where and with which variables the session runs.
    public init(language: KernelLanguage, locator: InterpreterLocator = .shared, executable: String? = nil,
                directory: URL? = nil, environment extra: [String: String] = [:]) throws {
        self.language = language
        let wanted = executable ?? language.command[0]
        guard let exe = locator.find(wanted) else {
            throw CodeRunnerError.interpreterMissing(language.id, [wanted])
        }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("folio-kernel-\(UUID().uuidString).\(language.fileExtension)")
        scriptURL = script
        try language.script.write(to: script, atomically: true, encoding: .utf8)
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = language.command.dropFirst().map { $0.replacingOccurrences(of: "{script}", with: script.path) }
        var env = locator.environment
        env["PYTHONIOENCODING"] = "utf-8"
        for (k, v) in extra { env[k] = v }
        process.environment = env
        process.currentDirectoryURL = directory ?? FileManager.default.homeDirectoryForCurrentUser
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        input = inPipe.fileHandleForWriting
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in self?.receive(h.availableData, isErr: false) }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in self?.receive(h.availableData, isErr: true) }
        process.terminationHandler = { [weak self] _ in self?.terminated() }
        try process.run()
    }

    deinit { shutdown() }

    public func shutdown() {
        if process.isRunning { ServerDetector.terminateTree(process.processIdentifier) }
        try? FileManager.default.removeItem(at: scriptURL)
    }

    /// Stops the code that is running right now (like Ctrl-C), keeping the session's variables.
    public func interrupt() {
        guard process.isRunning else { return }
        // Programs started by the code (e.g. `sleep` in a shell session) get the interrupt too.
        for child in ServerDetector.descendants(of: process.processIdentifier) { kill(child, SIGINT) }
        kill(process.processIdentifier, SIGINT)
        lock.lock(); let interruptedID = current?.id; lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let interruptedID else { return }
            self.lock.lock(); let active = self.current?.id == interruptedID; self.lock.unlock()
            if active { self.shutdown() }
        }
    }

    // MARK: Running code

    /// Runs `code` in the shared namespace. Output streams through `onOutput`; runs are queued.
    public func execute(_ code: String, timeout: TimeInterval = 30, stdin: String? = nil, limits: ResourceLimits = ResourceLimits(), onOutput: (@Sendable (String) -> Void)? = nil,
                        onServer: (@Sendable (URL) -> Void)? = nil) async -> RunResult {
        let start = Date()
        let server = LockedBool()
        let memoryHit = LockedBool()
        var message = ["op": "exec", "code": code]
        if let stdin { message["stdin"] = stdin }
        let (out, err, status, timedOut) = await send(message, timeout: timeout, keepRunning: { server.value }, limits: limits, memoryHit: memoryHit,
                                                      onOutput: { chunk in
            onOutput?(chunk)
            if let url = ServerDetector.url(inOutput: chunk), !server.value { server.set(); onServer?(url) }
        })
        var result = RunResult(stdout: out, stderr: err, exitCode: status == "ok" ? 0 : 1, duration: Date().timeIntervalSince(start),
                               command: "\(language.id)-Sitzung", timedOut: timedOut, cancelled: false)
        if server.value { result.serverURL = ServerDetector.url(inOutput: out + err) }
        result.memoryExceeded = memoryHit.value
        result.fileName = "<block>"
        return result
    }

    /// Names visible in the session (no receiver) or members of `receiver`, evaluated without side effects.
    public func complete(receiver: String?) async -> [String] {
        guard language.supportsCompletion, isAlive else { return [] }
        let (out, _, status, _) = await send(["op": "complete", "receiver": receiver ?? ""], timeout: 2, keepRunning: { false }, onOutput: nil)
        guard status == "ok", let line = out.split(separator: "\n").last,
              let data = line.data(using: .utf8), let names = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return names
    }

    private func send(_ message: [String: String], timeout: TimeInterval, keepRunning: @escaping @Sendable () -> Bool,
                      limits: ResourceLimits = ResourceLimits(), memoryHit: LockedBool = LockedBool(),
                      onOutput: (@Sendable (String) -> Void)?) async -> (String, String, String, Bool) {
        await withCheckedContinuation { cont in
            let id = UUID().uuidString
            let start: () -> Void = { [weak self] in
                guard let self, self.process.isRunning else {
                    self?.lock.lock(); self?.busy = false; self?.lock.unlock()
                    cont.resume(returning: ("", "Die Sitzung läuft nicht mehr.", "error", false))
                    return
                }
                let timedOut = LockedBool()
                self.lock.lock()
                self.current = (id, onOutput, false, false, OutputLimiter(limit: limits.maxOutputBytes), OutputLimiter(limit: limits.maxOutputBytes / 2), "ok", nil)
                self.current?.finish = { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    guard self.current?.id == id else { self.lock.unlock(); return }
                    let c = self.current
                    self.current = nil
                    self.busy = false
                    let next = self.queue.isEmpty ? nil : self.queue.removeFirst()
                    if next != nil { self.busy = true }
                    self.lock.unlock()
                    cont.resume(returning: (c?.stdout.text ?? "", c?.stderr.text ?? "", c?.status ?? "error", timedOut.value))
                    if let next { DispatchQueue.global().async(execute: next) }
                }
                self.lock.unlock()
                var msg: [String: String] = message
                msg["id"] = id
                guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
                try? self.input.write(contentsOf: data + Data("\n".utf8))
                if limits.maxMemoryMB > 0 {
                    DispatchQueue.global().async { [weak self] in
                        while let self, self.process.isRunning {
                            self.lock.lock(); let active = self.current?.id == id; self.lock.unlock()
                            guard active else { return }
                            let tree = [self.pid] + ServerDetector.descendants(of: self.pid)
                            if ServerDetector.residentMemoryMB(of: tree) > limits.maxMemoryMB {
                                memoryHit.set()
                                self.shutdown()
                                return
                            }
                            Thread.sleep(forTimeInterval: 0.5)
                        }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); let stillRunning = self.current?.id == id; self.lock.unlock()
                    // A recognized server keeps running until it is stopped.
                    if stillRunning, !keepRunning() { timedOut.set(); self.interrupt() }
                }
            }
            lock.lock()
            if busy {
                queue.append(start)
                lock.unlock()
            } else {
                busy = true
                lock.unlock()
                start()
            }
        }
    }

    private func receive(_ data: Data, isErr: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if isErr { errBuffer.append(data) } else { outBuffer.append(data) }
        var finish: (() -> Void)?
        // Process complete lines; stream partial output as it comes.
        let marker: UInt8 = 0x1E
        while true {
            let buffer = isErr ? errBuffer : outBuffer
            guard !buffer.isEmpty else { break }
            if let m = buffer.firstIndex(of: marker) {
                let text = String(decoding: buffer[buffer.startIndex..<m], as: UTF8.self)
                guard let nl = buffer[m...].firstIndex(of: 10) else {
                    // Marker line not complete yet: emit text before it and wait.
                    if !text.isEmpty { emit(text, isErr: isErr) }
                    if isErr { errBuffer.removeSubrange(errBuffer.startIndex..<m) } else { outBuffer.removeSubrange(outBuffer.startIndex..<m) }
                    break
                }
                if !text.isEmpty { emit(text, isErr: isErr) }
                let markerLine = String(decoding: buffer[buffer.index(after: m)..<nl], as: UTF8.self)
                if isErr { errBuffer.removeSubrange(errBuffer.startIndex...nl) } else { outBuffer.removeSubrange(outBuffer.startIndex...nl) }
                let parts = markerLine.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[0] == current?.id ?? "" {
                    if isErr { current?.errDone = true } else { current?.outDone = true; current?.status = String(parts[1]) }
                    if current?.outDone == true && current?.errDone == true { finish = current?.finish }
                }
            } else {
                let text = String(decoding: buffer, as: UTF8.self)
                emit(text, isErr: isErr)
                if isErr { errBuffer.removeAll() } else { outBuffer.removeAll() }
                break
            }
        }
        lock.unlock()
        finish?()
    }

    /// Called with `lock` held.
    private func emit(_ text: String, isErr: Bool) {
        if isErr { current?.stderr.append(Data(text.utf8)) } else { current?.stdout.append(Data(text.utf8)) }
        if let cb = current?.onOutput { DispatchQueue.global().async { cb(text) } }
    }

    private func terminated() {
        lock.lock()
        current?.status = "error"
        current?.stderr.append(Data("\nDie Sitzung wurde beendet.".utf8))
        let finish = current?.finish
        let pending = queue
        queue.removeAll()
        lock.unlock()
        finish?()
        pending.forEach { $0() }
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
}

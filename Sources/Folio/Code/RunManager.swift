import AppKit
import Combine
import FolioCore

/// Keeps code runs alive independently of the views showing them, so a server started in a note keeps
/// running (and stays stoppable) while you switch notes. Everything still running is stopped on quit.
@MainActor
final class RunManager: ObservableObject {
    static let shared = RunManager()

    struct Run {
        var runner: CodeRun
        var kernel: Kernel?
        var server: URL?
        var started = Date()
        var stopped = false
    }

    @Published private(set) var runs: [UUID: Run] = [:]
    @Published private(set) var info: [UUID: String] = [:]
    /// Notes whose block tests are running, and the result of the last automatic run (#29).
    @Published private(set) var testingNotes: Set<UUID> = []
    @Published private(set) var testSummaries: [UUID: BlockTestSummary] = [:]

    func isRunning(_ id: UUID) -> Bool { runs[id] != nil }
    /// Whether the running block takes typed input (interactive runs as their own process).
    func acceptsInput(_ id: UUID) -> Bool { runs[id]?.kernel == nil && runs[id]?.runner.acceptsInput == true }
    func send(_ text: String, to id: UUID) { runs[id]?.runner.send(text) }
    func endInput(_ id: UUID) { objectWillChange.send(); runs[id]?.runner.closeInput() }
    func server(_ id: UUID) -> URL? { runs[id]?.server }

    /// Runs a block. Linked blocks of a language with a shared session run in the note's kernel, so they
    /// see each other's variables; others run as a separate process. Returns when the run has finished.
    @discardableResult
    func start(block: BlockModel, doc: NoteDocument, theme: ThemeManager) -> Task<Void, Never>? {
        guard runs[block.id] == nil else { return nil }
        let lang = Languages.spec(for: block.language)
        let env = doc.meta.environment
        let stdin = (block.stdin ?? "").isEmpty ? nil : block.stdin
        // Typed input needs its own process; prepared input works in Python sessions too.
        let needsOwnProcess = block.interactive || (stdin != nil && lang.id != "python")
        let shared = block.mode != "isolated" && KernelManager.supportsSharing(lang.id) && !needsOwnProcess
        guard lang.isRunnable || shared else { return nil }
        let id = block.id
        let runner = CodeRun()
        var kernel: Kernel?
        if shared {
            do { kernel = try KernelManager.shared.kernel(note: doc.id, language: lang.id, environment: env) } catch {
                block.output = error.localizedDescription
                block.outputIsError = true
                return nil
            }
        }
        runs[id] = Run(runner: runner, kernel: kernel)
        info[id] = "läuft…"
        block.output = ""
        block.outputIsError = false
        block.outputCollapsed = false
        block.diagnostics = []
        block.testOutcome = nil
        let code = block.storage.string
        let noteOverride = env?.interpreters[lang.id].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let override = noteOverride ?? theme.settings.interpreterOverrides[lang.id]
        let timeout = env?.timeout ?? theme.settings.runTimeout
        let limits = ResourceLimits(timeout: timeout, maxOutputBytes: Int(theme.settings.maxOutputKB * 1024),
                                    maxMemoryMB: Int(theme.settings.maxMemoryMB), killOrphans: theme.settings.killOrphans)
        let options = RunOptions(stdin: stdin, interactive: block.interactive, workingDirectory: env?.workingDirectoryURL,
                                 environment: env?.variables ?? [:], limits: limits)
        let lineCount = code.components(separatedBy: "\n").count
        let output = OutputBuffer(limit: limits.maxOutputBytes)
        let onOutput: @Sendable (String) -> Void = { chunk in
            // Coalesce output so a chatty server doesn't redraw the note for every line.
            if output.append(chunk) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    MainActor.assumeIsolated {
                        guard self.runs[id]?.runner === runner else { return }
                        block.output = output.flush()
                    }
                }
            }
        }
        let onServer: @Sendable (URL) -> Void = { url in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.runs[id]?.server = url
                    self.info[id] = "Server läuft · \(url.host() ?? "localhost"):\(url.port ?? 80)"
                }
            }
        }

        if block.interactive {
            Task {
                while self.runs[id]?.runner === runner {
                    if runner.acceptsInput { self.objectWillChange.send(); break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
        return Task {
            do {
                let r: RunResult
                if let kernel {
                    r = await kernel.execute(code, timeout: timeout, stdin: stdin, limits: limits, onOutput: onOutput, onServer: onServer)
                } else {
                    r = try await runner.run(code: code, language: lang, override: override, options: options,
                                             onOutput: onOutput, onServer: onServer)
                }
                let stopped = r.cancelled || runs[id]?.stopped == true
                var text = r.combinedOutput
                if r.timedOut { text += "\n⏱ Abgebrochen nach \(Int(timeout)) s (Zeitlimit)" }
                if r.memoryExceeded { text += "\n⛔︎ Abgebrochen: mehr als \(limits.maxMemoryMB) MB Arbeitsspeicher (Limit in den Einstellungen)" }
                if stopped { text += r.serverURL != nil ? "\n■ Server gestoppt" : "\n■ Gestoppt" }
                block.output = text
                block.outputIsError = !r.succeeded && !(stopped && r.serverURL != nil)
                if block.outputIsError || !r.stderr.isEmpty {
                    block.diagnostics = DiagnosticParser.parse(r.combinedOutput, fileName: r.fileName, lineCount: lineCount)
                }
                if let test = block.test {
                    // A regular expression can take seconds; the interface has to keep running (#134).
                    block.testOutcome = await Task.detached(priority: .userInitiated) { BlockTestEvaluator.evaluate(test, result: r) }.value
                }
                if kernel != nil {
                    block.ranInSession = r.succeeded || (stopped && r.serverURL != nil)
                    block.startedServer = r.serverURL != nil
                }
                info[id] = kernel != nil
                    ? String(format: "%@ · %.2f s", r.succeeded ? "verknüpft" : "Fehler", r.duration)
                    : String(format: "%@ · Exit %d · %.2f s", r.command, r.exitCode, r.duration)
            } catch {
                block.output = error.localizedDescription
                block.outputIsError = true
                info[id] = nil
                if block.test != nil { block.testOutcome = .notRun(error.localizedDescription) }
            }
            runs[id] = nil
            doc.markDirty()
        }
    }

    /// Runs every code block of the note from top to bottom, waiting for each.
    func runAll(doc: NoteDocument, theme: ThemeManager) {
        let blocks = doc.blocks.filter { $0.kind == .code }
        Task {
            for b in blocks {
                await start(block: b, doc: doc, theme: theme)?.value
                if b.outputIsError { break }
            }
        }
    }

    /// Runs the note's block tests top to bottom and collects the results. Blocks without a test only run when a
    /// later test shares their session; unlike `runAll`, a failed test does not end the run.
    func runTests(doc: NoteDocument, theme: ThemeManager) {
        guard !testingNotes.contains(doc.id) else { return }
        let blocks = doc.blocks.filter { $0.kind == .code && !($0.language == "sql" && $0.connection != nil) }
        let items = blocks.map { b in
            BlockTestPlan.Item(id: b.id, hasTest: b.test != nil,
                               session: b.mode != "isolated" && KernelManager.supportsSharing(b.language) ? b.language : nil,
                               interactive: b.interactive, startsServer: b.startedServer)
        }
        let steps = BlockTestPlan.steps(for: items)
        testingNotes.insert(doc.id)
        testSummaries[doc.id] = nil
        Task {
            for step in steps {
                guard let block = blocks.first(where: { $0.id == step.id }) else { continue }
                switch step.action {
                case .skip(let reason):
                    block.testOutcome = .notRun(reason)
                case .setup:
                    await start(block: block, doc: doc, theme: theme)?.value
                case .test:
                    if let run = start(block: block, doc: doc, theme: theme) {
                        await run.value
                    } else {
                        block.testOutcome = .notRun(isRunning(block.id) ? "Der Block läuft bereits." : (block.output ?? "Der Block kann nicht ausgeführt werden."))
                    }
                }
            }
            testSummaries[doc.id] = BlockTestSummary(blocks.filter { $0.test != nil }.compactMap(\.testOutcome))
            testingNotes.remove(doc.id)
        }
    }

    /// Stops a run. In a shared session only the running code is interrupted; variables stay.
    func stop(_ id: UUID) {
        runs[id]?.stopped = true
        if let kernel = runs[id]?.kernel { kernel.interrupt() } else { runs[id]?.runner.cancel() }
    }

    func clearInfo(_ id: UUID) { info[id] = nil }

    func stopAll() {
        for run in runs.values { run.kernel?.interrupt(); run.runner.cancel() }
    }
}

/// Thread-safe accumulator for streamed output; `append` returns true when a flush should be scheduled.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var limiter: OutputLimiter
    private var pending = false

    init(limit: Int) { limiter = OutputLimiter(limit: limit) }

    func append(_ chunk: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        limiter.append(Data(chunk.utf8))
        if pending { return false }
        pending = true
        return true
    }

    func flush() -> String {
        lock.lock(); defer { lock.unlock() }
        pending = false
        return limiter.text
    }
}

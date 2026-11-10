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
        let shared = runsInSession(block, language: lang.id)
        guard lang.isRunnable || shared else { return nil }
        var kernel: Kernel?
        if shared {
            kernel = openKernel(for: block, doc: doc, language: lang.id)
            guard kernel != nil else { return nil }
        }
        let runner = CodeRun()
        begin(block, runner: runner, kernel: kernel)
        let context = makeContext(block: block, doc: doc, theme: theme, language: lang, runner: runner, kernel: kernel)
        if block.interactive { announceInputWhenReady(block.id, runner: runner) }
        return Task { await self.execute(context) }
    }

    /// Everything a started run needs until it has finished.
    private struct RunContext {
        let block: BlockModel
        let doc: NoteDocument
        let language: LanguageSpec
        let runner: CodeRun
        let kernel: Kernel?
        let code: String
        let override: String?
        let timeout: TimeInterval
        let limits: ResourceLimits
        let options: RunOptions
        let onOutput: @Sendable (String) -> Void
        let onServer: @Sendable (URL) -> Void
    }

    private func preparedInput(of block: BlockModel) -> String? {
        (block.stdin ?? "").isEmpty ? nil : block.stdin
    }

    /// Typed input needs its own process; prepared input works in Python sessions too.
    private func runsInSession(_ block: BlockModel, language: String) -> Bool {
        let needsOwnProcess = block.interactive || (preparedInput(of: block) != nil && language != "python")
        return block.mode != "isolated" && KernelManager.supportsSharing(language) && !needsOwnProcess
    }

    private func openKernel(for block: BlockModel, doc: NoteDocument, language: String) -> Kernel? {
        do {
            return try KernelManager.shared.kernel(note: doc.id, language: language, environment: doc.meta.environment)
        } catch {
            block.output = error.localizedDescription
            block.outputIsError = true
            return nil
        }
    }

    private func begin(_ block: BlockModel, runner: CodeRun, kernel: Kernel?) {
        runs[block.id] = Run(runner: runner, kernel: kernel)
        info[block.id] = "läuft…"
        block.output = ""
        block.outputIsError = false
        block.outputCollapsed = false
        block.diagnostics = []
        block.testOutcome = nil
    }

    private func makeContext(block: BlockModel, doc: NoteDocument, theme: ThemeManager, language: LanguageSpec, runner: CodeRun, kernel: Kernel?) -> RunContext {
        let env = doc.meta.environment
        let noteOverride = env?.interpreters[language.id].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let timeout = env?.timeout ?? theme.settings.runTimeout
        let limits = ResourceLimits(timeout: timeout, maxOutputBytes: Int(theme.settings.maxOutputKB * 1024),
                                    maxMemoryMB: Int(theme.settings.maxMemoryMB), killOrphans: theme.settings.killOrphans)
        let options = RunOptions(stdin: preparedInput(of: block), interactive: block.interactive, workingDirectory: env?.workingDirectoryURL,
                                 environment: env?.variables ?? [:], limits: limits)
        return RunContext(block: block, doc: doc, language: language, runner: runner, kernel: kernel, code: block.storage.string,
                          override: noteOverride ?? theme.settings.interpreterOverrides[language.id], timeout: timeout, limits: limits, options: options,
                          onOutput: outputHandler(for: block, runner: runner, limit: limits.maxOutputBytes), onServer: serverHandler(for: block.id))
    }

    /// Coalesces output so a chatty server doesn't redraw the note for every line.
    private func outputHandler(for block: BlockModel, runner: CodeRun, limit: Int) -> @Sendable (String) -> Void {
        let id = block.id
        let output = OutputBuffer(limit: limit)
        return { chunk in
            guard output.append(chunk) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MainActor.assumeIsolated {
                    guard self.runs[id]?.runner === runner else { return }
                    block.output = output.flush()
                }
            }
        }
    }

    private func serverHandler(for id: UUID) -> @Sendable (URL) -> Void {
        { url in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.runs[id]?.server = url
                    self.info[id] = "Server läuft · \(url.host() ?? "localhost"):\(url.port ?? 80)"
                }
            }
        }
    }

    private func announceInputWhenReady(_ id: UUID, runner: CodeRun) {
        Task {
            while self.runs[id]?.runner === runner {
                if runner.acceptsInput { self.objectWillChange.send(); break }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func execute(_ c: RunContext) async {
        do {
            await finish(c, with: try await perform(c))
        } catch {
            c.block.output = error.localizedDescription
            c.block.outputIsError = true
            info[c.block.id] = nil
            if c.block.test != nil { c.block.testOutcome = .notRun(error.localizedDescription) }
        }
        runs[c.block.id] = nil
        c.doc.markDirty()
    }

    private func perform(_ c: RunContext) async throws -> RunResult {
        if let kernel = c.kernel {
            return await kernel.execute(c.code, timeout: c.timeout, stdin: preparedInput(of: c.block), limits: c.limits, onOutput: c.onOutput, onServer: c.onServer)
        }
        return try await c.runner.run(code: c.code, language: c.language, override: c.override, options: c.options, onOutput: c.onOutput, onServer: c.onServer)
    }

    private func finish(_ c: RunContext, with r: RunResult) async {
        let block = c.block
        let stopped = r.cancelled || runs[block.id]?.stopped == true
        block.output = outputText(of: r, context: c, stopped: stopped)
        block.outputIsError = !r.succeeded && !(stopped && r.serverURL != nil)
        if block.outputIsError || !r.stderr.isEmpty {
            block.diagnostics = DiagnosticParser.parse(r.combinedOutput, fileName: r.fileName, lineCount: c.code.components(separatedBy: "\n").count)
        }
        if let test = block.test {
            // A regular expression can take seconds; the interface has to keep running (#134).
            block.testOutcome = await Task.detached(priority: .userInitiated) { BlockTestEvaluator.evaluate(test, result: r) }.value
        }
        if c.kernel != nil {
            block.ranInSession = r.succeeded || (stopped && r.serverURL != nil)
            block.startedServer = r.serverURL != nil
        }
        info[block.id] = c.kernel != nil
            ? String(format: "%@ · %.2f s", r.succeeded ? "verknüpft" : "Fehler", r.duration)
            : String(format: "%@ · Exit %d · %.2f s", r.command, r.exitCode, r.duration)
    }

    private func outputText(of r: RunResult, context c: RunContext, stopped: Bool) -> String {
        var text = r.combinedOutput
        if r.timedOut { text += "\n⏱ Abgebrochen nach \(Int(c.timeout)) s (Zeitlimit)" }
        if r.memoryExceeded { text += "\n⛔︎ Abgebrochen: mehr als \(c.limits.maxMemoryMB) MB Arbeitsspeicher (Limit in den Einstellungen)" }
        if stopped { text += r.serverURL != nil ? "\n■ Server gestoppt" : "\n■ Gestoppt" }
        return text
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
        let steps = BlockTestPlan.steps(for: blocks.map(testPlanItem))
        testingNotes.insert(doc.id)
        testSummaries[doc.id] = nil
        Task {
            for step in steps {
                if let block = blocks.first(where: { $0.id == step.id }) { await perform(step.action, on: block, doc: doc, theme: theme) }
            }
            testSummaries[doc.id] = BlockTestSummary(blocks.filter { $0.test != nil }.compactMap(\.testOutcome))
            testingNotes.remove(doc.id)
        }
    }

    private func testPlanItem(_ b: BlockModel) -> BlockTestPlan.Item {
        BlockTestPlan.Item(id: b.id, hasTest: b.test != nil,
                           session: b.mode != "isolated" && KernelManager.supportsSharing(b.language) ? b.language : nil,
                           interactive: b.interactive, startsServer: b.startedServer)
    }

    private func perform(_ action: BlockTestPlan.Action, on block: BlockModel, doc: NoteDocument, theme: ThemeManager) async {
        switch action {
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

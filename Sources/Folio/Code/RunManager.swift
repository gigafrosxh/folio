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

    func isRunning(_ id: UUID) -> Bool { runs[id] != nil }
    func server(_ id: UUID) -> URL? { runs[id]?.server }

    /// Runs a block. Linked blocks of a language with a shared session run in the note's kernel, so they
    /// see each other's variables; others run as a separate process. Returns when the run has finished.
    @discardableResult
    func start(block: BlockModel, doc: NoteDocument, theme: ThemeManager) -> Task<Void, Never>? {
        guard runs[block.id] == nil else { return nil }
        let lang = Languages.spec(for: block.language)
        let shared = block.mode != "isolated" && KernelManager.supportsSharing(lang.id)
        guard lang.isRunnable || shared else { return nil }
        let id = block.id
        let runner = CodeRun()
        var kernel: Kernel?
        if shared {
            do { kernel = try KernelManager.shared.kernel(note: doc.id, language: lang.id) } catch {
                block.output = error.localizedDescription
                block.outputIsError = true
                return nil
            }
        }
        runs[id] = Run(runner: runner, kernel: kernel)
        info[id] = "läuft…"
        block.output = ""
        block.outputIsError = false
        let code = block.storage.string
        let override = theme.settings.interpreterOverrides[lang.id]
        let timeout = theme.settings.runTimeout
        let output = OutputBuffer()
        let onOutput: @Sendable (String) -> Void = { chunk in
            // Coalesce output so a chatty server doesn't redraw the note for every line.
            if output.append(chunk) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    MainActor.assumeIsolated { block.output = output.flush() }
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

        return Task {
            do {
                let r: RunResult
                if let kernel {
                    r = await kernel.execute(code, timeout: timeout, onOutput: onOutput, onServer: onServer)
                } else {
                    r = try await runner.run(code: code, language: lang, override: override, timeout: timeout,
                                             onOutput: onOutput, onServer: onServer)
                }
                let stopped = r.cancelled || runs[id]?.stopped == true
                var text = r.combinedOutput
                if r.timedOut { text += "\n⏱ Abgebrochen nach \(Int(timeout)) s" }
                if stopped { text += r.serverURL != nil ? "\n■ Server gestoppt" : "\n■ Gestoppt" }
                block.output = text
                block.outputIsError = !r.succeeded && !(stopped && r.serverURL != nil)
                info[id] = kernel != nil
                    ? String(format: "%@ · %.2f s", r.succeeded ? "verknüpft" : "Fehler", r.duration)
                    : String(format: "%@ · Exit %d · %.2f s", r.command, r.exitCode, r.duration)
            } catch {
                block.output = error.localizedDescription
                block.outputIsError = true
                info[id] = nil
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
    private var text = ""
    private var pending = false
    private let limit = 200_000

    func append(_ chunk: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        text += chunk
        if text.count > limit { text = "…\n" + String(text.suffix(limit)) }
        if pending { return false }
        pending = true
        return true
    }

    func flush() -> String {
        lock.lock(); defer { lock.unlock() }
        pending = false
        return text
    }
}

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
        var server: URL?
        var started = Date()
    }

    @Published private(set) var runs: [UUID: Run] = [:]
    @Published private(set) var info: [UUID: String] = [:]

    func isRunning(_ id: UUID) -> Bool { runs[id] != nil }
    func server(_ id: UUID) -> URL? { runs[id]?.server }

    func start(block: BlockModel, doc: NoteDocument, theme: ThemeManager) {
        guard runs[block.id] == nil else { return }
        let lang = Languages.spec(for: block.language)
        guard lang.isRunnable else { return }
        let runner = CodeRun()
        let id = block.id
        runs[id] = Run(runner: runner)
        info[id] = "läuft…"
        block.output = ""
        block.outputIsError = false
        let code = block.storage.string
        let override = theme.settings.interpreterOverrides[lang.id]
        let timeout = theme.settings.runTimeout
        let output = OutputBuffer()

        Task {
            do {
                let r = try await runner.run(
                    code: code, language: lang, override: override, timeout: timeout,
                    onOutput: { chunk in
                        // Coalesce output so a chatty server doesn't redraw the note for every line.
                        if output.append(chunk) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                block.output = output.flush()
                            }
                        }
                    },
                    onServer: { url in
                        DispatchQueue.main.async {
                            self.runs[id]?.server = url
                            self.info[id] = "Server läuft · \(url.host() ?? "localhost"):\(url.port ?? 80)"
                        }
                    })
                var text = r.combinedOutput
                if r.timedOut { text += "\n⏱ Abgebrochen nach \(Int(timeout)) s" }
                if r.cancelled { text += r.serverURL != nil ? "\n■ Server gestoppt" : "\n■ Gestoppt" }
                block.output = text
                block.outputIsError = !r.succeeded && !(r.cancelled && r.serverURL != nil)
                info[id] = String(format: "%@ · Exit %d · %.2f s", r.command, r.exitCode, r.duration)
            } catch {
                block.output = error.localizedDescription
                block.outputIsError = true
                info[id] = nil
            }
            runs[id] = nil
            doc.markDirty()
        }
    }

    func stop(_ id: UUID) { runs[id]?.runner.cancel() }

    func clearInfo(_ id: UUID) { info[id] = nil }

    func stopAll() {
        for run in runs.values { run.runner.cancel() }
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

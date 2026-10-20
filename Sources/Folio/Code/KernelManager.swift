import Foundation
import FolioCore

/// One shared interpreter session per note and language, so code blocks in a note see each other's
/// variables like notebook cells. Sessions end when the note is closed or the app quits.
@MainActor
final class KernelManager: ObservableObject {
    static let shared = KernelManager()

    @Published private(set) var alive: Set<String> = []
    private var kernels: [String: Kernel] = [:]

    private func key(_ note: UUID, _ language: String) -> String { "\(note.uuidString)|\(language)" }

    static func supportsSharing(_ language: String) -> Bool { KernelLanguages.spec(for: language) != nil }

    /// The running session, starting one if needed.
    func kernel(note: UUID, language: String, environment env: RunEnvironment? = nil) throws -> Kernel? {
        guard let spec = KernelLanguages.spec(for: language) else { return nil }
        let k = key(note, language)
        if let existing = kernels[k], existing.isAlive { return existing }
        let env = env ?? NoteStore.shared.document(for: note)?.meta.environment
        // A per-note interpreter ("python3.12 {file}") replaces the session's executable.
        let exe = env?.interpreters[language]?.split(separator: " ").first.map(String.init)
        let kernel = try Kernel(language: spec, executable: exe, directory: env?.workingDirectoryURL, environment: env?.variables ?? [:])
        kernels[k] = kernel
        alive.insert(k)
        return kernel
    }

    /// The session only if it is already running (for autocomplete, which must not start interpreters).
    func existing(note: UUID, language: String) -> Kernel? {
        let k = key(note, language)
        guard let kernel = kernels[k], kernel.isAlive else { return nil }
        return kernel
    }

    func isRunning(note: UUID, language: String) -> Bool { existing(note: note, language: language) != nil }

    func restart(note: UUID, language: String) {
        let k = key(note, language)
        // Nothing has run in the fresh session yet.
        if let doc = NoteStore.shared.currentDocument, doc.id == note {
            for b in doc.blocks where b.kind == .code && b.language == language { b.ranInSession = false }
        }
        kernels.removeValue(forKey: k)?.shutdown()
        alive.remove(k)
    }

    /// A linked block was deleted: start the session over so its names disappear, then quietly re-run the
    /// remaining linked blocks of that language that had run successfully (top to bottom), so their
    /// variables are back. Blocks that started servers are not re-run.
    func blockRemoved(_ block: BlockModel, from doc: NoteDocument) {
        let language = block.language
        guard block.mode != "isolated", block.ranInSession, isRunning(note: doc.id, language: language) else { return }
        let replay = doc.blocks.filter {
            $0.kind == .code && $0.language == language && $0.mode != "isolated" && $0.ranInSession && !$0.startedServer
        }
        restart(note: doc.id, language: language)
        for b in doc.blocks where b.kind == .code && b.language == language { b.ranInSession = false }
        guard !replay.isEmpty, let kernel = try? kernel(note: doc.id, language: language) else { return }
        let codes = replay.map { ($0, $0.storage.string) }
        Task {
            for (b, code) in codes {
                let r = await kernel.execute(code, timeout: 30)
                b.ranInSession = r.succeeded
                if !r.succeeded { break }
            }
        }
    }

    func shutdown(note: UUID) {
        for (k, kernel) in kernels where k.hasPrefix(note.uuidString) {
            kernel.shutdown()
            kernels[k] = nil
            alive.remove(k)
        }
    }

    func shutdownAll() {
        kernels.values.forEach { $0.shutdown() }
        kernels.removeAll()
        alive.removeAll()
    }
}

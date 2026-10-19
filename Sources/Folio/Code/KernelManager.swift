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
    func kernel(note: UUID, language: String) throws -> Kernel? {
        guard let spec = KernelLanguages.spec(for: language) else { return nil }
        let k = key(note, language)
        if let existing = kernels[k], existing.isAlive { return existing }
        let kernel = try Kernel(language: spec)
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
        kernels.removeValue(forKey: k)?.shutdown()
        alive.remove(k)
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

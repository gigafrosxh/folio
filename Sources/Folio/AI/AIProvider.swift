import Foundation
import FolioCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether the chosen Ollama answers and has the chosen model (#237). Checked when the chat opens and before
/// each question; while it does not, the chat shows matching passages instead of an answer.
@MainActor
final class OllamaStatus: ObservableObject {
    static let shared = OllamaStatus()
    @Published private(set) var problem: String?

    func refresh() async {
        let s = ThemeManager.shared.settings
        do {
            let client = try AIProvider.ollama()
            let models = try await client.models()
            if s.ollamaModel.isEmpty { set(OllamaClient.Failure.noModel.errorDescription) }
            else if !models.contains(s.ollamaModel) { set("„\(s.ollamaModel)“ ist in Ollama nicht installiert oder kann keinen Text schreiben. Wähle ein anderes Modell in den Einstellungen (Editor › KI).") }
            else { set(nil) }
        } catch {
            set((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func set(_ value: String?) { if problem != value { problem = value } }
}

/// Which model answers: Apple Intelligence (default) or a local Ollama the user chose (#42). Chat, AI actions and
/// tag suggestions all go through here.
@MainActor
enum AIProvider {
    enum Failure: Error, LocalizedError {
        case unavailable(String)
        var errorDescription: String? { if case .unavailable(let s) = self { return s }; return nil }
    }

    static var usesOllama: Bool { ThemeManager.shared.settings.aiProvider == "ollama" }

    /// Shown in the chat header and in messages.
    static var name: String {
        usesOllama ? "Ollama (\(ThemeManager.shared.settings.ollamaModel.isEmpty ? "kein Modell" : ThemeManager.shared.settings.ollamaModel))" : "Apple Intelligence"
    }

    static func ollama() throws -> OllamaClient {
        let s = ThemeManager.shared.settings
        return try OllamaClient(baseURL: s.ollamaURL, model: s.ollamaModel)
    }

    /// A one-off answer without tools, streamed into `onPart` (the whole text so far).
    static func complete(system: String, prompt: String, onPart: @escaping @MainActor (String) -> Void = { _ in }) async throws -> String {
        if usesOllama {
            let client = try ollama()
            return try await client.chat(system: system, prompt: prompt) { text in
                Task { @MainActor in onPart(text) }
            }
        }
        let availability = AIAvailability.current
        guard availability.isAvailable else { throw Failure.unavailable("\(availability.title). \(availability.explanation)") }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: system)
            var text = ""
            for try await partial in session.streamResponse(to: prompt) {
                try Task.checkCancellation()
                text = partial.content
                onPart(text)
            }
            return text
        }
        #endif
        throw Failure.unavailable(AIAvailability.current.explanation)
    }
}

import Foundation
import FolioCore
#if canImport(FoundationModels)
import FoundationModels
#endif

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

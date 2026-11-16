import Foundation

/// A local Ollama server as an opt-in AI provider (#42). Only addresses on this Mac are allowed, so notes never
/// leave it; Apple Intelligence stays the default.
public struct OllamaClient: Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case notLocal(String)
        case notRunning(String)
        case noModel
        case modelMissing(String)
        case notChat(String)
        case server(String)

        public var errorDescription: String? {
            switch self {
            case .notLocal(let url): return "„\(url)“ ist kein Server auf diesem Mac. Folio spricht nur mit einem lokalen Ollama (localhost), damit Notizen den Mac nicht verlassen."
            case .notRunning(let url): return "Ollama antwortet nicht unter \(url). Starte die Ollama-App oder im Terminal `ollama serve`."
            case .noModel: return "In Ollama ist noch kein Modell ausgewählt. Wähle eines in den Einstellungen (Allgemein › KI) oder lade eines mit `ollama pull llama3.2`."
            case .modelMissing(let name): return "Das Modell „\(name)“ ist in Ollama nicht installiert. Lade es mit `ollama pull \(name)` oder wähle ein anderes."
            case .notChat(let name): return "„\(name)“ kann keinen Text schreiben (z. B. ein Embedding-Modell). Wähle in den Einstellungen (Allgemein › KI) ein anderes Modell, etwa `gemma3` oder `llama3.2`."
            case .server(let message): return "Ollama meldet einen Fehler: \(message)"
            }
        }
    }

    public let baseURL: URL
    public let model: String
    let session: URLSession

    /// Nil for anything that is not an http(s) address on this Mac.
    public static func localURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "http://" + trimmed),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host()?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".localhost") else { return nil }
        return url
    }

    public init(baseURL: String, model: String, session: URLSession = .shared) throws {
        guard let url = Self.localURL(baseURL) else { throw Failure.notLocal(baseURL) }
        self.baseURL = url
        self.model = model
        self.session = session
    }

    /// Installed models that can write text, by name. Embedding-only models are left out (#225); older Ollama
    /// versions report no capabilities, then every model counts.
    public func models() async throws -> [String] {
        try Self.chatModels(in: await get("api/tags"))
    }

    static func chatModels(in data: Data) throws -> [String] {
        struct Tags: Decodable { struct Model: Decodable { var name: String; var capabilities: [String]? }; var models: [Model] }
        guard let tags = try? JSONDecoder().decode(Tags.self, from: data) else { throw Failure.server("unerwartete Antwort auf /api/tags") }
        return tags.models.filter { $0.capabilities.map { $0.contains("completion") } ?? true }.map(\.name).sorted()
    }

    public struct Message: Codable, Equatable, Sendable {
        public var role: String
        public var content: String
        public init(role: String, content: String) { self.role = role; self.content = content }
    }

    /// The answer, streamed: `onPart` gets the whole text so far after each piece.
    public func chat(system: String, prompt: String, onPart: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        guard !model.isEmpty else { throw Failure.noModel }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        struct Body: Encodable { var model: String; var messages: [Message]; var stream: Bool }
        request.httpBody = try JSONEncoder().encode(Body(model: model, messages: [Message(role: "system", content: system), Message(role: "user", content: prompt)], stream: true))
        let (bytes, response) = try await call { try await session.bytes(for: request) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw Self.failure(status: http.statusCode, body: body, model: model)
        }
        var text = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let piece = Self.piece(line) else { continue }
            if let error = piece.error { throw Failure.server(error) }
            text += piece.content
            onPart(text)
            if piece.done { break }
        }
        return text
    }

    /// One line of Ollama's streamed answer (NDJSON).
    public static func piece(_ line: String) -> (content: String, done: Bool, error: String?)? {
        struct Line: Decodable { var message: Message?; var done: Bool?; var error: String? }
        guard let data = line.data(using: .utf8), let l = try? JSONDecoder().decode(Line.self, from: data) else { return nil }
        return (l.message?.content ?? "", l.done ?? false, l.error)
    }

    static func failure(status: Int, body: String, model: String) -> Failure {
        if status == 404, body.lowercased().contains("not found") { return .modelMissing(model) }
        if body.lowercased().contains("does not support chat") || body.lowercased().contains("does not support generate") { return .notChat(model) }
        struct E: Decodable { var error: String }
        let message = (try? JSONDecoder().decode(E.self, from: Data(body.utf8)))?.error ?? "HTTP \(status)"
        return .server(message)
    }

    private func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 5
        let (data, response) = try await call { try await session.data(for: request) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Self.failure(status: http.statusCode, body: String(decoding: data, as: UTF8.self), model: model)
        }
        return data
    }

    /// Connection problems become „Ollama läuft nicht“.
    private func call<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet:
                throw Failure.notRunning(baseURL.absoluteString)
            default: throw error
            }
        }
    }
}

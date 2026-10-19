import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A conversation with the on-device Apple Intelligence model about one note. Conversations live for the
/// app session, one per note, so switching notes and back keeps the chat.
@MainActor
final class AIChatModel: ObservableObject, Identifiable {
    enum Role { case user, assistant }

    struct Message: Identifiable, Equatable {
        let id = UUID()
        var role: Role
        var text: String
        var isStreaming = false
    }

    /// Ready-made prompts shown as chips.
    struct QuickAction: Identifiable {
        let id = UUID()
        var title: String
        var icon: String
        var prompt: String
    }

    static let quickActions: [QuickAction] = [
        QuickAction(title: "Zusammenfassen", icon: "text.redaction", prompt: "Fasse die Notiz in wenigen Sätzen zusammen."),
        QuickAction(title: "Stichpunkte", icon: "list.bullet", prompt: "Mach aus der Notiz eine übersichtliche Stichpunktliste."),
        QuickAction(title: "Aufgaben finden", icon: "checklist", prompt: "Welche Aufgaben oder To-dos stecken in der Notiz? Liste sie als Checkliste."),
        QuickAction(title: "Fragen dazu", icon: "questionmark.bubble", prompt: "Stelle drei sinnvolle Rückfragen zum Inhalt der Notiz."),
        QuickAction(title: "Auf Englisch", icon: "globe", prompt: "Übersetze die Notiz ins Englische."),
    ]

    let noteID: UUID
    @Published private(set) var messages: [Message] = []
    @Published private(set) var isResponding = false
    @Published var errorText: String?
    /// Whether the selected text (if any) is sent along with the next question.
    @Published var includeSelection = true

    /// Supplies the current note text and selection when a question is sent.
    var noteProvider: () -> (title: String, text: String, selection: String?) = { ("", "", nil) }

    private var task: Task<Void, Never>?
    #if canImport(FoundationModels)
    private var sessionStorage: Any?
    #endif

    private static var chats: [UUID: AIChatModel] = [:]

    static func forNote(_ id: UUID) -> AIChatModel {
        if let c = chats[id] { return c }
        let c = AIChatModel(noteID: id)
        chats[id] = c
        return c
    }

    private init(noteID: UUID) { self.noteID = noteID }

    var availability: TextPredictor.Status { TextPredictor.status }

    var hasSelection: Bool { !(noteProvider().selection ?? "").isEmpty }

    func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }
        errorText = nil
        messages.append(Message(role: .user, text: question))
        messages.append(Message(role: .assistant, text: "", isStreaming: true))
        isResponding = true
        let note = noteProvider()
        let selection = includeSelection ? note.selection : nil
        task = Task { [weak self] in
            await self?.respond(to: question, note: note, selection: selection)
        }
    }

    func stop() {
        task?.cancel()
        finishStreaming()
    }

    /// Starts a fresh conversation (the model forgets earlier turns).
    func reset() {
        stop()
        messages.removeAll()
        errorText = nil
        #if canImport(FoundationModels)
        sessionStorage = nil
        #endif
    }

    private func finishStreaming() {
        if let i = messages.lastIndex(where: { $0.isStreaming }) {
            messages[i].isStreaming = false
            if messages[i].text.isEmpty { messages.remove(at: i) }
        }
        isResponding = false
    }

    private func respond(to question: String, note: (title: String, text: String, selection: String?), selection: String?) async {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = TextPredictor.status else {
                if case .unavailable(let reason) = TextPredictor.status { errorText = reason }
                finishStreaming()
                return
            }
            let session: LanguageModelSession
            if let s = sessionStorage as? LanguageModelSession {
                session = s
            } else {
                session = LanguageModelSession(instructions: """
                Du bist ein hilfreicher Assistent in der Notizen-App Folio und läufst komplett auf dem Mac. \
                Antworte in der Sprache der Frage, knapp und klar. Nutze Markdown (Listen, **fett**) wo es hilft. \
                Beziehe dich auf die Notiz des Nutzers, wenn die Frage sie betrifft; erfinde nichts, was nicht darin steht.
                """)
                sessionStorage = session
            }
            // The on-device model has a small context window, so the note is trimmed.
            var prompt = ""
            if session.transcript.count <= 1 || selection != nil {
                prompt += "Notiz „\(note.title)“:\n\"\"\"\n\(String(note.text.prefix(6000)))\n\"\"\"\n\n"
            }
            if let selection, !selection.isEmpty {
                prompt += "Markierter Text:\n\"\"\"\n\(String(selection.prefix(2000)))\n\"\"\"\n\n"
            }
            prompt += question
            do {
                for try await partial in session.streamResponse(to: prompt) {
                    if Task.isCancelled { break }
                    if let i = messages.lastIndex(where: { $0.isStreaming }) { messages[i].text = partial.content }
                }
            } catch {
                if !Task.isCancelled {
                    errorText = Self.describe(error)
                    // A full context window cannot continue; start over next time.
                    sessionStorage = nil
                }
            }
            finishStreaming()
            return
        }
        #endif
        errorText = "Der KI-Chat benötigt macOS 26 mit Apple Intelligence."
        finishStreaming()
    }

    private static func describe(_ error: Error) -> String {
        let text = String(describing: error)
        if text.contains("exceededContextWindowSize") {
            return "Die Unterhaltung ist zu lang für das Sprachmodell auf dem Gerät. Mit „Neu“ beginnst du von vorn."
        }
        if text.contains("guardrailViolation") {
            return "Apple Intelligence hat diese Anfrage aus Sicherheitsgründen abgelehnt."
        }
        return "Apple Intelligence konnte nicht antworten: \(error.localizedDescription)"
    }
}

import AppKit
import Foundation
import FolioCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A conversation with the on-device Apple Intelligence model, either about one note (plus notes added
/// for comparing) or about the whole library. Conversations are saved in the library (#33); every answer
/// keeps the passages it was given, numbered, so citations like [2] link to the exact place (#35).
@MainActor
final class AIChatModel: ObservableObject, Identifiable {
    enum Scope: Equatable {
        case note(UUID)
        case library
    }

    struct Message: Identifiable, Equatable {
        var id = UUID()
        var role: ChatRecord.Role
        var text: String
        var isStreaming = false
        var sources: [Passage] = []
        var usedTokens: Int?
        var omitted = 0
        /// Answer made without the model (search results only).
        var isFallback = false
        /// What the assistant changed in the notes for this answer (#124).
        var actions: [NoteAgent.Action] = []
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

    static let compareAction = QuickAction(title: "Vergleichen", icon: "square.split.2x1",
                                           prompt: "Vergleiche die Notizen: Was haben sie gemeinsam, worin unterscheiden sie sich, und wo widersprechen sie sich?")

    static let libraryActions: [QuickAction] = [
        QuickAction(title: "Offene Aufgaben", icon: "checklist", prompt: "Welche offenen Aufgaben stehen in meinen Notizen?"),
        QuickAction(title: "Termine", icon: "calendar", prompt: "Welche Termine und Fristen kommen in meinen Notizen vor?"),
    ]

    let scope: Scope
    var noteID: UUID? { if case .note(let id) = scope { return id }; return nil }
    @Published private(set) var messages: [Message] = []
    @Published private(set) var isResponding = false
    @Published var errorText: String?
    /// Whether the selected text (if any) is sent along with the next question.
    @Published var includeSelection = true
    /// Other notes in this conversation, for comparing (#34).
    @Published private(set) var extraNotes: [UUID] = []

    /// Supplies the current note text and selection when a question is sent.
    var noteProvider: () -> (title: String, text: String, selection: String?) = { ("", "", nil) }

    private var task: Task<Void, Never>?
    private static var chats: [String: AIChatModel] = [:]

    static func forNote(_ id: UUID) -> AIChatModel { model(for: .note(id)) }
    static func forLibrary() -> AIChatModel { model(for: .library) }

    private static func model(for scope: Scope) -> AIChatModel {
        let key = Self.key(scope)
        if let c = chats[key] { return c }
        let c = AIChatModel(scope: scope)
        chats[key] = c
        return c
    }

    private static func key(_ scope: Scope) -> String {
        if case .note(let id) = scope { return ChatArchive.key(note: id) }
        return ChatArchive.key(note: nil)
    }

    /// Forgets loaded conversations (another library was opened).
    static func resetCache() { chats.removeAll() }

    private var archive: ChatArchive { ChatArchive(library: NoteStore.shared.rootURL) }

    private init(scope: Scope) {
        self.scope = scope
        let saved = archive.load(Self.key(scope))
        messages = saved.messages.map {
            Message(id: $0.id, role: $0.role, text: $0.text, sources: $0.sources, usedTokens: $0.usedTokens)
        }
        extraNotes = saved.extraNotes.filter { id in NoteStore.shared.notes.contains { $0.id == id } }
    }

    var availability: AIAvailability { AIAvailability.current }
    var hasSelection: Bool { !(noteProvider().selection ?? "").isEmpty }

    // MARK: Notes in the conversation (#34)

    func addNote(_ id: UUID) {
        guard id != noteID, !extraNotes.contains(id) else { return }
        extraNotes.append(id)
        persist()
    }

    func removeNote(_ id: UUID) {
        extraNotes.removeAll { $0 == id }
        persist()
    }

    func title(of id: UUID) -> String {
        let t = NoteStore.shared.notes.first { $0.id == id }?.meta.title ?? ""
        return t.isEmpty ? "Ohne Titel" : t
    }

    // MARK: Context (#39)

    /// What the next question would send (without the question's own ranking).
    var contextPreview: ContextPlan { ContextBuilder.plan(candidates(for: "")) }

    private func passages(ofNote id: UUID) -> [Passage] {
        let store = NoteStore.shared
        let title = store.notes.first { $0.id == id }?.meta.title ?? ""
        let text: String
        if id == noteID {
            text = noteProvider().text
        } else if let doc = store.document(for: id) {
            text = NoteText.of(doc.makeFilePreview())
        } else {
            text = store.notes.first { $0.id == id }?.meta.searchText ?? ""
        }
        return Passages.split(noteID: id, title: title, text: text)
    }

    /// Passages in the order they should be offered to the model for `question`.
    private func candidates(for question: String) -> [Passage] {
        switch scope {
        case .library:
            let all = NoteStore.shared.notes.flatMap { ref in
                Passages.split(noteID: ref.id, title: ref.meta.title, text: ref.meta.searchText)
            }
            return PassageIndex(all).search(question, limit: 14).map(\.passage)
        case .note(let id):
            let groups = ([id] + extraNotes).map(passages(ofNote:))
            func ranked(_ ps: [Passage]) -> [Passage] {
                guard !question.isEmpty else { return ps }
                let hits = PassageIndex(ps).search(question, limit: ps.count).map(\.passage)
                // Relevant passages first, then the rest in note order, so short notes are still complete.
                return hits + ps.filter { p in !hits.contains(p) }
            }
            if groups.count == 1 { return ranked(groups[0]) }
            // Comparing: take passages from every note in turn so none is crowded out.
            let lists = groups.map(ranked)
            var out: [Passage] = []
            for i in 0..<(lists.map(\.count).max() ?? 0) {
                for list in lists where i < list.count { out.append(list[i]) }
            }
            return out
        }
    }

    // MARK: Asking

    func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }
        errorText = nil
        let history = transcript.recentTurns(budget: 450)
        messages.append(Message(role: .user, text: question))
        let selection = includeSelection && scope != .library ? noteProvider().selection : nil
        let plan = ContextBuilder.plan(candidates(for: question),
                                       budget: ContextBuilder.sourceBudget - TokenEstimate.tokens(selection ?? "").clamped(to: 0...800))
        messages.append(Message(role: .assistant, text: "", isStreaming: true, sources: plan.passages,
                                usedTokens: plan.usedTokens, omitted: plan.omitted))
        isResponding = true
        task = Task { [weak self] in
            await self?.respond(question, plan: plan, history: history, selection: selection)
        }
    }

    func stop() {
        task?.cancel()
        finishStreaming()
    }

    /// Starts a fresh conversation and deletes the saved one.
    func reset() {
        stop()
        messages.removeAll()
        errorText = nil
        persist()
    }

    private func finishStreaming() {
        if let i = messages.lastIndex(where: { $0.isStreaming }) {
            messages[i].isStreaming = false
            if messages[i].text.isEmpty { messages.remove(at: i) }
        }
        isResponding = false
        persist()
    }

    private var transcript: ChatTranscript {
        ChatTranscript(messages: messages.filter { !$0.isStreaming }.map {
            ChatRecord(id: $0.id, role: $0.role, text: $0.text, sources: $0.sources, usedTokens: $0.usedTokens)
        }, extraNotes: extraNotes)
    }

    private func persist() {
        try? archive.save(transcript, key: Self.key(scope))
    }

    private static let instructions = """
    Du bist der Assistent der Notizen-App Folio und läufst komplett auf dem Mac. Antworte in der Sprache des Nutzers, \
    knapp und direkt, in ganzen Sätzen; Listen nur, wenn der Nutzer eine Liste will.
    Aufträge führst du sofort mit einem Werkzeug aus: Notiz anlegen (notizAnlegen), Text ergänzen (textAnfuegen), \
    verknüpfen (notizenVerknuepfen), taggen (tagHinzufuegen), umbenennen (notizUmbenennen), verschieben (notizVerschieben). \
    Kündige nie nur an, was du tun wirst – ruf das Werkzeug auf und sag danach in einem Satz, was erledigt ist. \
    Kennst du den genauen Titel einer Notiz nicht, nutze zuerst notizenSuchen.
    Bei Fragen zum Inhalt stütze dich nur auf die nummerierten Quellen und schreib hinter jede Aussage die Quelle in \
    eckigen Klammern, z. B. [1]. Wenn die Quellen die Frage nicht beantworten, sag das ehrlich.
    """

    private func respond(_ question: String, plan: ContextPlan, history: String, selection: String?) async {
        guard case .available = availability.state else {
            // Without Apple Intelligence: show where the answer probably is (#41).
            answerWithoutModel(plan)
            return
        }
        var prompt = ""
        if !history.isEmpty { prompt += "Bisheriges Gespräch:\n\(history)\n\n" }
        if !plan.passages.isEmpty { prompt += "Quellen:\n\(ContextBuilder.sourceBlock(plan))\n\n" }
        else { prompt += "Es wurden keine passenden Stellen in den Notizen gefunden.\n\n" }
        if let selection, !selection.isEmpty { prompt += "Markierter Text:\n\"\"\"\n\(String(selection.prefix(2400)))\n\"\"\"\n\n" }
        prompt += "Frage: \(question)"
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // A fresh session per question: recent turns travel in the prompt, so conversations survive
            // restarts and never overflow the small context window.
            // With tools the assistant carries out tasks on the notes instead of only talking about them (#124).
            let session = LanguageModelSession(tools: NoteAgentTools.all, instructions: Self.instructions)
            NoteAgent.log = []
            do {
                for try await partial in session.streamResponse(to: prompt) {
                    if Task.isCancelled { break }
                    if let i = messages.lastIndex(where: { $0.isStreaming }) {
                        messages[i].text = partial.content
                        messages[i].actions = NoteAgent.log
                    }
                }
            } catch {
                if !Task.isCancelled { errorText = Self.describe(error) }
            }
            if let i = messages.lastIndex(where: { $0.isStreaming }) {
                messages[i].actions = NoteAgent.log
                if messages[i].text.isEmpty, !NoteAgent.log.isEmpty { messages[i].text = "Erledigt." }
            }
            finishStreaming()
            return
        }
        #endif
        answerWithoutModel(plan)
    }

    private func answerWithoutModel(_ plan: ContextPlan) {
        guard let i = messages.lastIndex(where: { $0.isStreaming }) else { return }
        if plan.passages.isEmpty {
            messages[i].text = "Ohne Apple Intelligence kann ich nicht antworten, und in den Notizen passt keine Stelle zu den Suchbegriffen."
        } else {
            let lines = plan.passages.prefix(6).enumerated().map { n, p in "- **\(p.noteTitle.isEmpty ? "Notiz" : p.noteTitle)** [\(n + 1)]: \(p.excerpt)" }
            messages[i].text = "Ohne Apple Intelligence gibt es keine formulierte Antwort, aber diese Stellen passen zu deiner Frage:\n\n" + lines.joined(separator: "\n")
        }
        messages[i].isFallback = true
        finishStreaming()
    }

    private static func describe(_ error: Error) -> String {
        let text = String(describing: error)
        if text.contains("exceededContextWindowSize") {
            return "Die Anfrage ist zu groß für das Sprachmodell auf dem Gerät. Stell die Frage kürzer oder nimm Notizen aus dem Vergleich heraus."
        }
        if text.contains("guardrailViolation") {
            return "Apple Intelligence hat diese Anfrage aus Sicherheitsgründen abgelehnt."
        }
        if text.contains("unsupportedLanguage") || text.contains("unsupportedLanguageOrLocale") {
            return "Apple Intelligence unterstützt diese Sprache auf diesem Mac noch nicht."
        }
        return "Apple Intelligence konnte nicht antworten: \(error.localizedDescription)"
    }
}

private extension Int {
    func clamped(to r: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, r.lowerBound), r.upperBound) }
}

/// Why Apple Intelligence can or cannot be used, with what the user can do about it (#41).
struct AIAvailability {
    enum State: Equatable { case available, notEnabled, notReady, unsupportedMac, unsupportedSystem, other(String) }

    var state: State

    static var current: AIAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return AIAvailability(state: .available)
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: return AIAvailability(state: .notEnabled)
                case .deviceNotEligible: return AIAvailability(state: .unsupportedMac)
                case .modelNotReady: return AIAvailability(state: .notReady)
                @unknown default: return AIAvailability(state: .other("Apple Intelligence ist nicht verfügbar."))
                }
            }
        }
        #endif
        return AIAvailability(state: .unsupportedSystem)
    }

    var isAvailable: Bool { state == .available }

    var title: String {
        switch state {
        case .available: return "Apple Intelligence ist bereit"
        case .notEnabled: return "Apple Intelligence ist ausgeschaltet"
        case .notReady: return "Apple Intelligence wird noch geladen"
        case .unsupportedMac: return "Dieser Mac unterstützt Apple Intelligence nicht"
        case .unsupportedSystem: return "Apple Intelligence braucht macOS 26"
        case .other: return "Apple Intelligence ist nicht verfügbar"
        }
    }

    var explanation: String {
        switch state {
        case .available: return ""
        case .notEnabled: return "Schalte Apple Intelligence in den Systemeinstellungen ein. Bis dahin zeigt Folio passende Stellen aus deinen Notizen statt einer formulierten Antwort."
        case .notReady: return "macOS lädt das Sprachmodell gerade herunter. Das kann einige Minuten dauern; danach funktioniert der Chat ohne Neustart."
        case .unsupportedMac: return "Apple Intelligence braucht einen Mac mit Apple-Chip (M1 oder neuer). Alles andere in Folio funktioniert normal; Fragen beantwortet Folio mit passenden Stellen aus deinen Notizen."
        case .unsupportedSystem: return "Aktualisiere auf macOS 26, um den Chat, Textvorschläge und KI-Antworten zu nutzen. Bis dahin findet Folio passende Stellen in deinen Notizen."
        case .other(let reason): return reason
        }
    }

    /// Opens the Apple Intelligence settings, if that helps.
    var settingsURL: URL? {
        switch state {
        case .notEnabled, .notReady: return URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")
        case .unsupportedSystem: return URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
        default: return nil
        }
    }
}

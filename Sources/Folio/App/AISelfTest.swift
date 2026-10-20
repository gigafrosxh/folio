import AppKit
import FolioCore

/// Asks Apple Intelligence real questions about a throwaway library (FOLIO_AI_TEST=1): answers, sources,
/// saved conversations, library questions and comparing.
@MainActor
enum AISelfTest {
    private static func check(_ ok: Bool, _ label: String) {
        print(ok ? "AI ok" : "AI FAIL", label)
        fflush(stdout)
    }

    private static func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    private static func ask(_ chat: AIChatModel, _ q: String) async -> AIChatModel.Message? {
        chat.send(q)
        for _ in 0..<240 where chat.isResponding { await wait(0.25) }
        return chat.messages.last
    }

    static func run() async {
        let store = NoteStore.shared
        await wait(2)
        let availability = AIAvailability.current
        print("AI availability", availability.state); fflush(stdout)
        let body = ThemeManager.shared.bodyAttributes
        func make(_ text: String) -> UUID? {
            guard let ref = store.createNote(), let doc = store.currentDocument else { return nil }
            doc.blocks[0].storage.setAttributedString(NSAttributedString(string: text, attributes: body))
            doc.markDirty(); doc.saveNow()
            return ref.id
        }
        guard let a = make("Urlaub Portugal\nFlug nach Lissabon am 3. Mai um 7:40 Uhr. Hotel Alfama, Zimmer 12."),
              let b = make("Urlaub Spanien\nFlug nach Madrid am 9. Juni. Hotel Sol, zwei Nächte.") else { check(false, "Notizen"); return }
        store.selectedNoteID = a
        await wait(0.5)
        let chat = AIChatModel.forNote(a)
        chat.noteProvider = { ("Urlaub Portugal", "Urlaub Portugal\nFlug nach Lissabon am 3. Mai um 7:40 Uhr. Hotel Alfama, Zimmer 12.", nil) }
        chat.reset()
        let answer = await ask(chat, "Wann geht der Flug?")
        let text = answer?.text ?? ""
        print("AI answer:", text.replacingOccurrences(of: "\n", with: " ").prefix(200)); fflush(stdout)
        check(answer?.role == .assistant && !text.isEmpty, "Antwort erhalten\(chat.errorText.map { " (Fehler: \($0))" } ?? "")")
        check(text.contains("3") || text.lowercased().contains("mai") || answer?.isFallback == true, "Antwort nennt das Datum")
        check(!(answer?.sources.isEmpty ?? true), "Antwort hat Quellen")
        check(availability.isAvailable == false || !CitationParser.citations(in: text, sourceCount: answer?.sources.count ?? 0).isEmpty,
              "Antwort zitiert eine Quelle mit [n]")

        AIChatModel.resetCache()
        check(AIChatModel.forNote(a).messages.count == chat.messages.count, "Verlauf nach Neuladen erhalten (\(chat.messages.count) Nachrichten)")

        let cmp = AIChatModel.forNote(a)
        cmp.noteProvider = chat.noteProvider
        cmp.addNote(b)
        let c = await ask(cmp, "Vergleiche die Notizen: Wohin gehen die Flüge?")
        check(Set(c?.sources.map(\.noteID) ?? []) == [a, b], "Vergleich sieht beide Notizen")
        print("AI compare:", (c?.text ?? "").replacingOccurrences(of: "\n", with: " ").prefix(200)); fflush(stdout)

        let lib = AIChatModel.forLibrary()
        lib.reset()
        let l = await ask(lib, "Welches Hotel in Madrid?")
        check(l?.sources.contains { $0.noteID == b } == true, "Bibliotheksfrage findet die richtige Notiz")
        print("AI library:", (l?.text ?? "").replacingOccurrences(of: "\n", with: " ").prefix(200)); fflush(stdout)
        print("AI done"); fflush(stdout)
    }
}

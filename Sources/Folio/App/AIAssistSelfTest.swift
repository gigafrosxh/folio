import AppKit
import FolioCore

/// 1.6.0 AI features without a model: the context menu (#36), answers as blocks (#40), tags from suggestions
/// (#37) and the Ollama settings (#42). Runs as part of FOLIO_ORG_TEST.
@MainActor
enum AIAssistSelfTest {
    private static func check(_ ok: Bool, _ label: String) {
        print(ok ? "ORG ok" : "ORG FAIL", label)
        fflush(stdout)
    }

    static func run(store: NoteStore) async {
        menuChecks()
        await ollamaChecks()
        guard let ref = store.createNote(titled: "KI-Probe", body: "Waschmaschine kaputt"),
              let doc = await opened(ref.id, store: store) else { return check(false, "KI-Notiz angelegt") }
        doc.undoManager?.beginUndoGrouping()
        doc.appendTag("haushalt")
        doc.insertAnswerBlocks("Plan:\n```py\nprint(1)\n```\n| A | B |\n|---|---|\n| 1 | 2 |", after: doc.blocks.first?.id, theme: ThemeManager.shared)
        doc.undoManager?.endUndoGrouping()
        doc.saveNow()
        let saved = (try? NoteFile.read(from: doc.url))
        check(saved?.meta.tags.contains("haushalt") == true, "Tag-Vorschlag gespeichert")
        let kinds = doc.blocks.map(\.kind)
        check(kinds.filter { $0 == .code }.count == 1 && doc.blocks.contains { $0.language == "python" }, "KI-Antwort mit Code als Codeblock")
        check(doc.blocks.contains { $0.storage.string == "A\tB\n1\t2" }, "KI-Antwort mit Tabelle als Textblock")
    }

    private static func opened(_ id: UUID, store: NoteStore) async -> NoteDocument? {
        store.open(noteID: id)
        for _ in 0..<20 {
            if let doc = store.document(for: id) { return doc }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func menuChecks() {
        let tv = FolioTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        tv.string = "Die Photosynthese wandelt Licht in Energie."
        tv.blockID = UUID()
        check(tv.aiActionsItem() == nil, "Kein KI-Menü ohne Auswahl")
        tv.setSelectedRange(NSRange(location: 4, length: 13))
        let titles = tv.aiActionsItem()?.submenu?.items.map(\.title) ?? []
        check(titles.count == 4 && titles.first?.hasPrefix("Erkl") == true, "KI-Menü mit vier Aktionen")
        tv.setSelectedRange(NSRange(location: 3, length: 1))
        check(tv.aiActionsItem() == nil, "Kein KI-Menü für Leerzeichen")
    }

    private static func ollamaChecks() async {
        let settings = ThemeManager.shared.settings
        check(settings.aiProvider == "apple" && !AIProvider.usesOllama, "Apple Intelligence ist voreingestellt")
        do {
            _ = try await OllamaClient(baseURL: "127.0.0.1:9", model: "x").models()
            check(false, "Ollama nicht erreichbar gemeldet")
        } catch {
            var notRunning = false
            if case .notRunning = error as? OllamaClient.Failure { notRunning = true }
            check(notRunning, "Ollama nicht erreichbar gemeldet")
        }
        check((try? OllamaClient(baseURL: "http://example.com:11434", model: "x")) == nil, "Ollama nur lokal")
    }
}

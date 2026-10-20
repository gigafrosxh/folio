import AppKit
import FolioCore

/// End-to-end check of quick capture, the waiting queue, deep links, the global shortcut and the AI
/// chat's saved conversations (FOLIO_QUICK_TEST=1 with throwaway FOLIO_LIBRARY and FOLIO_CAPTURE_QUEUE).
@MainActor
enum QuickAccessSelfTest {
    private static func check(_ ok: Bool, _ label: String) {
        print(ok ? "QUICK ok" : "QUICK FAIL", label)
        fflush(stdout)
    }

    private static func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    static func run() async {
        let store = NoteStore.shared
        let service = CaptureService.shared
        await wait(2)

        // Capture into the inbox (#87)
        var r = service.save(CaptureItem(text: "Erste Idee https://example.com/x"))
        check(r.ok, "Erfassung in die Inbox: \(r.message)")
        let inbox = store.notes.first { $0.url.lastPathComponent == "Inbox.folio" }
        check(inbox != nil && inbox?.meta.pinned == true && inbox?.meta.title == "Inbox", "Inbox-Notiz angelegt und angepinnt")
        if let inbox, let file = try? NoteFile.read(from: inbox.url) {
            check(file.body.blocks.contains { $0.kind == .web && $0.url == "https://example.com/x" }, "Link als Vorschau-Block")
            check(inbox.meta.searchText.contains("Erste Idee"), "Erfasster Text ist durchsuchbar")
        }
        r = service.save(CaptureItem(text: "Zweite Idee"))
        let inbox2 = store.notes.filter { $0.url.lastPathComponent.hasPrefix("Inbox") }
        check(inbox2.count == 1 && inbox2.first?.meta.searchText.contains("Zweite Idee") == true, "Zweite Erfassung landet in derselben Inbox")

        // Capture into a note that is open with unsaved edits
        guard let target = store.createNote(), let doc = store.currentDocument else { check(false, "Zielnotiz"); return }
        doc.blocks[0].storage.setAttributedString(NSAttributedString(string: "Zielnotiz\nUngespeicherte Zeile", attributes: ThemeManager.shared.bodyAttributes))
        doc.markDirty()
        r = service.save(CaptureItem(text: "In die offene Notiz", target: .note(target.id)))
        let text = doc.blocks.map(\.storage.string).joined(separator: "\n")
        check(r.ok && text.contains("Ungespeicherte Zeile") && text.contains("In die offene Notiz"), "Erfassung in offene Notiz behält ungesicherte Änderungen")
        check(store.conflict == nil, "Kein Konflikt durch die Erfassung")

        // Capture into a closed note
        guard let other = store.createNote() else { return }
        store.selectedNoteID = target.id
        store.closeTab(other.id)
        await wait(0.3)
        let titleBefore = store.notes.first { $0.id == other.id }?.meta.title
        r = service.save(CaptureItem(text: "In die geschlossene Notiz", target: .note(other.id)))
        let otherAfter = store.notes.first { $0.id == other.id }
        check(r.ok && otherAfter?.meta.searchText.contains("In die geschlossene Notiz") == true, "Erfassung in geschlossene Notiz")
        // An empty target takes the first captured line as title, never the date line (#95).
        check(otherAfter?.meta.title == "In die geschlossene Notiz", "Leere Zielnotiz heißt wie die erste erfasste Zeile (\(titleBefore ?? "-") → \(otherAfter?.meta.title ?? "-"))")

        // Library not writable: the capture waits and is delivered later (#93)
        let root = store.rootURL
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        r = service.save(CaptureItem(text: "Wartet auf Schreibrechte"))
        check(r.ok && service.pending.count == 1, "Ohne Schreibrecht wartet die Erfassung (\(r.message))")
        service.retryPending()
        check(service.pending.count == 1, "Erneuter Versuch ohne Schreibrecht bleibt in der Warteschlange")
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        service.retryPending()
        check(service.pending.isEmpty && store.notes.contains { $0.meta.searchText.contains("Wartet auf Schreibrechte") }, "Nach Freigabe nachgetragen")

        // Missing target note: not queued forever, text stays
        r = service.save(CaptureItem(text: "Ziel weg", target: .note(UUID())))
        check(!r.ok, "Fehlende Zielnotiz wird gemeldet: \(r.message)")

        // Draft survives closing with Esc
        let model = QuickCaptureController.shared.model
        model.text = "Entwurf bleibt"
        QuickCaptureController.shared.close()
        check(QuickCaptureModel().text == "Entwurf bleibt", "Entwurf bleibt nach dem Schließen erhalten")
        model.discard()
        check(QuickCaptureModel().text.isEmpty, "Verwerfen löscht den Entwurf")

        // Deep links (#89)
        DeepLinks.perform(.openNote(other.id, passage: nil))
        check(store.currentDocument?.id == other.id, "folio://note öffnet die Notiz")
        DeepLinks.perform(.search("Inbox"))
        check(store.searchText == "Inbox", "folio://search setzt die Suche")
        store.searchText = ""
        let before = store.notes.count
        DeepLinks.perform(.newNote(title: "Aus Link", text: "Inhalt"))
        store.currentDocument?.saveNow()
        check(store.notes.count == before + 1 && store.currentDocument?.meta.title == "Aus Link", "folio://new legt eine Notiz an (\(store.currentDocument?.meta.title ?? "-"))")
        DeepLinks.perform(.capture(text: "Vom Link", target: .inbox))
        check(QuickCaptureController.shared.isVisible && QuickCaptureController.shared.model.text.contains("Vom Link"), "folio://capture öffnet die Schnellerfassung vorausgefüllt")
        QuickCaptureController.shared.model.discard()
        QuickCaptureController.shared.close()
        DeepLinks.perform(.capture(text: nil, target: .note(UUID())))
        check(QuickCaptureController.shared.model.target == .inbox, "Unbekanntes Ziel im Link fällt auf die Inbox zurück")
        QuickCaptureController.shared.close()

        // Global shortcut (#86)
        GlobalHotKey.shared.register(KeyCombo(key: "j", control: true, option: true, command: true))
        check(GlobalHotKey.shared.isActive && GlobalHotKey.shared.problem == nil, "Globales Kürzel registriert")
        GlobalHotKey.shared.register(KeyCombo(key: "j"))
        check(!GlobalHotKey.shared.isActive && GlobalHotKey.shared.problem != nil, "Kürzel ohne Sondertaste wird abgelehnt")
        GlobalHotKey.shared.unregister()

        // Saved AI conversations (#33): written, reloaded, deleted
        let chat = AIChatModel.forNote(other.id)
        chat.addNote(target.id)
        AIChatModel.resetCache()
        let again = AIChatModel.forNote(other.id)
        check(again.extraNotes == [target.id], "KI-Chat: hinzugefügte Notiz bleibt nach Neuladen")
        again.removeNote(target.id)
        check(!FileManager.default.fileExists(atPath: LibraryData.folder(store.rootURL, "chats").appendingPathComponent(other.id.uuidString + ".json").path),
              "Leerer Chat hinterlässt keine Datei")
        print("QUICK done"); fflush(stdout)
    }
}

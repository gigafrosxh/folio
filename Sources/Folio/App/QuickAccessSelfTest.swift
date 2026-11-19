import AppKit
import SwiftUI
import FolioCore
import FolioWidgetData

/// End-to-end check of quick capture, the waiting queue, deep links, the global shortcut and the AI
/// chat's saved conversations (FOLIO_QUICK_TEST=1 with throwaway FOLIO_LIBRARY and FOLIO_CAPTURE_QUEUE).
@MainActor
enum QuickAccessSelfTest {
    private static func check(_ ok: Bool, _ label: String) {
        print(ok ? "QUICK ok" : "QUICK FAIL", label)
        fflush(stdout)
    }

    private static func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    /// The widget snapshot (#83, #84) from the test library: written outside the notes, no content by default.
    private static func widgetChecks(_ store: NoteStore) async {
        let theme = ThemeManager.shared
        _ = CaptureService.shared.save(CaptureItem(text: "☐ Milch\n☑ Brot\n☐ Äpfel"))
        theme.settings.widgetShowContent = false
        WidgetFeed.shared.update()
        let folder = WidgetFeed.shared.folder
        check(folder.path.hasPrefix(store.rootURL.path), "Widget-Snapshot der Testbibliothek bleibt in ihr (\(folder.lastPathComponent))")
        guard case .success(let s) = WidgetSnapshotStore.read(from: folder) else { check(false, "Widget-Snapshot lesbar"); return }
        check(s.pinned.contains { $0.title == "Inbox" } && !s.recent.isEmpty, "Widget kennt angepinnte und letzte Notizen")
        check(s.notes.allSatisfy { $0.preview == nil } && s.checklists.allSatisfy(\.items.isEmpty), "Ohne Erlaubnis keine Notizinhalte im Widget (#83)")
        let inbox = s.checklists.first { $0.title == "Inbox" }
        check(inbox?.done == 1 && inbox?.total == 3, "Checklisten-Fortschritt im Widget (\(inbox?.done ?? -1)/\(inbox?.total ?? -1))")
        theme.settings.widgetShowContent = true
        WidgetFeed.shared.update()
        if case .success(let shown) = WidgetSnapshotStore.read(from: folder) {
            check(shown.checklists.first { $0.title == "Inbox" }?.items.first?.text == "Milch", "Mit Erlaubnis zeigt das Widget Checklisten-Punkte")
        }
        theme.settings.widgetShowContent = false
        WidgetFeed.shared.update()
    }

    /// Dock drop and Services menu (#90, #91), without any dialog.
    private static func dropChecks(_ store: NoteStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-drop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("Ordner"), withIntermediateDirectories: true)
        let text = dir.appendingPathComponent("Plan.txt")
        try? Data("Plan".utf8).write(to: text)
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        let png = dir.appendingPathComponent("Rot.png")
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { try? rep.representation(using: .png, properties: [:])?.write(to: png) }
        let count = store.notes.count
        let problem = DropCapture.open([text, png, dir.appendingPathComponent("Ordner")])
        check(problem?.contains("Ordner") == true && problem?.contains("Plan") == false, "Ablegen: Ordner gemeldet, Rest übernommen")
        let dropped = store.notes.first { $0.meta.title.hasPrefix("Abgelegt am") }
        check(store.notes.count == count + 1 && dropped != nil, "Ablegen: neue Notiz für die Datei")
        if let dropped, let file = try? NoteFile.read(from: dropped.url) {
            check(file.body.blocks.contains { $0.kind == .file } && file.attachments.contains { $0.header.filename == "Plan.txt" }, "Ablegen: Datei als Anhang")
        }
        let inbox = store.notes.first { $0.meta.title == "Inbox" }.flatMap { try? NoteFile.read(from: $0.url) }
        check(inbox?.body.blocks.contains { $0.kind == .image } == true, "Ablegen: Bild in der Inbox")
        let pb = NSPasteboard(name: NSPasteboard.Name("folio-selftest-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("Aus dem Dienste-Menü", forType: .string)
        check(DropCapture.capture(pasteboard: pb) == nil, "Dienste-Menü: Auswahl gespeichert")
        check(store.notes.first { $0.meta.title == "Inbox" }.map { $0.meta.searchText.contains("Aus dem Dienste-Menü") } == true, "Dienste-Menü: Text in der Inbox")
        pb.releaseGlobally()
    }

    /// FOLIO_MENUBAR_SNAPSHOT=<png>: the menu bar panel with a favorite, for a visual check (#92).
    private static func menuBarSnapshot(_ store: NoteStore) {
        if let first = store.notes.first { store.organization.favorites = [first.id] }
        guard let path = ProcessInfo.processInfo.environment["FOLIO_MENUBAR_SNAPSHOT"] else { return }
        let renderer = ImageRenderer(content: MenuBarPanel().environmentObject(store).environmentObject(ThemeManager.shared))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return check(false, "Menüleisten-Bild") }
        try? png.write(to: URL(fileURLWithPath: path))
        check(true, "Menüleisten-Bild gesichert")
    }

    static func run() async {
        let store = NoteStore.shared
        let service = CaptureService.shared
        await wait(2)
        inboxChecks(store: store, service: service)
        // Capture into a note that is open with unsaved edits
        guard let target = store.createNote(), let doc = store.currentDocument else { check(false, "Zielnotiz"); return }
        openNoteCheck(store: store, service: service, target: target, doc: doc)
        guard let other = store.createNote() else { return }
        await closedNoteCheck(store: store, service: service, target: target, other: other)
        waitingQueueChecks(store: store, service: service)
        missingTargetCheck(service: service)
        draftChecks()
        deepLinkChecks(store: store, other: other)
        globalShortcutChecks()
        savedChatChecks(store: store, target: target, other: other)
        await widgetChecks(store)
        dropChecks(store)
        menuBarSnapshot(store)
        print("QUICK done"); fflush(stdout)
    }

    private static func inboxChecks(store: NoteStore, service: CaptureService) {
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
    }

    private static func openNoteCheck(store: NoteStore, service: CaptureService, target: NoteRef, doc: NoteDocument) {
        doc.blocks[0].storage.setAttributedString(NSAttributedString(string: "Zielnotiz\nUngespeicherte Zeile", attributes: ThemeManager.shared.bodyAttributes))
        doc.markDirty()
        let r = service.save(CaptureItem(text: "In die offene Notiz", target: .note(target.id)))
        let text = doc.blocks.map(\.storage.string).joined(separator: "\n")
        check(r.ok && text.contains("Ungespeicherte Zeile") && text.contains("In die offene Notiz"), "Erfassung in offene Notiz behält ungesicherte Änderungen")
        check(store.conflict == nil, "Kein Konflikt durch die Erfassung")
    }

    private static func closedNoteCheck(store: NoteStore, service: CaptureService, target: NoteRef, other: NoteRef) async {
        store.selectedNoteID = target.id
        store.closeTab(other.id)
        await wait(0.3)
        let titleBefore = store.notes.first { $0.id == other.id }?.meta.title
        let r = service.save(CaptureItem(text: "In die geschlossene Notiz", target: .note(other.id)))
        let otherAfter = store.notes.first { $0.id == other.id }
        check(r.ok && otherAfter?.meta.searchText.contains("In die geschlossene Notiz") == true, "Erfassung in geschlossene Notiz")
        // An empty target takes the first captured line as title, never the date line (#95).
        check(otherAfter?.meta.title == "In die geschlossene Notiz", "Leere Zielnotiz heißt wie die erste erfasste Zeile (\(titleBefore ?? "-") → \(otherAfter?.meta.title ?? "-"))")
    }

    private static func waitingQueueChecks(store: NoteStore, service: CaptureService) {
        // Library not writable: the capture waits and is delivered later (#93)
        let root = store.rootURL
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        var r = service.save(CaptureItem(text: "Wartet auf Schreibrechte"))
        check(r.ok && service.pending.count == 1, "Ohne Schreibrecht wartet die Erfassung (\(r.message))")
        service.retryPending()
        check(service.pending.count == 1, "Erneuter Versuch ohne Schreibrecht bleibt in der Warteschlange")
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        service.retryPending()
        check(service.pending.isEmpty && store.notes.contains { $0.meta.searchText.contains("Wartet auf Schreibrechte") }, "Nach Freigabe nachgetragen")
    }

    private static func missingTargetCheck(service: CaptureService) {
        // Missing target note: not queued forever, text stays
        let r = service.save(CaptureItem(text: "Ziel weg", target: .note(UUID())))
        check(!r.ok, "Fehlende Zielnotiz wird gemeldet: \(r.message)")
    }

    private static func draftChecks() {
        // Draft survives closing with Esc
        let model = QuickCaptureController.shared.model
        model.text = "Entwurf bleibt"
        QuickCaptureController.shared.close()
        check(QuickCaptureModel().text == "Entwurf bleibt", "Entwurf bleibt nach dem Schließen erhalten")
        model.discard()
        check(QuickCaptureModel().text.isEmpty, "Verwerfen löscht den Entwurf")
    }

    private static func deepLinkChecks(store: NoteStore, other: NoteRef) {
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
    }

    private static func globalShortcutChecks() {
        // Global shortcut (#86)
        GlobalHotKey.shared.register(KeyCombo(key: "j", control: true, option: true, command: true))
        check(GlobalHotKey.shared.isActive && GlobalHotKey.shared.problem == nil, "Globales Kürzel registriert")
        GlobalHotKey.shared.register(KeyCombo(key: "j"))
        check(!GlobalHotKey.shared.isActive && GlobalHotKey.shared.problem != nil, "Kürzel ohne Sondertaste wird abgelehnt")
        GlobalHotKey.shared.unregister()
    }

    private static func savedChatChecks(store: NoteStore, target: NoteRef, other: NoteRef) {
        // Saved AI conversations (#33): written, reloaded, deleted
        let chat = AIChatModel.forNote(other.id)
        chat.addNote(target.id)
        AIChatModel.resetCache()
        let again = AIChatModel.forNote(other.id)
        check(again.extraNotes == [target.id], "KI-Chat: hinzugefügte Notiz bleibt nach Neuladen")
        again.removeNote(target.id)
        check(!FileManager.default.fileExists(atPath: LibraryData.folder(store.rootURL, "chats").appendingPathComponent(other.id.uuidString + ".json").path),
              "Leerer Chat hinterlässt keine Datei")
    }
}

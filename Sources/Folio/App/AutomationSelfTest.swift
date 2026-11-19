import AppKit
import AppIntents
import FolioCore

/// Shortcuts and AppleScript (#70), FOLIO_AUTO_TEST: the shared automation, the Shortcuts actions run directly, and –
/// inside an app bundle with Folio.sdef – real AppleScript sent to this very process.
@MainActor
enum AutomationSelfTest {
    private static func check(_ ok: Bool, _ label: String) {
        print("AUTO", ok ? "ok" : "FAIL", label)
        fflush(stdout)
    }

    static func run() async {
        try? await Task.sleep(for: .seconds(1.5))
        let store = NoteStore.shared
        let made = try? NoteAutomation.create(title: "Automatisch angelegt", text: "Inhalt mit Zebra")
        check(made != nil && store.notes.contains { $0.meta.title == "Automatisch angelegt" }, "Notiz anlegen")
        check(NoteAutomation.search("zebra").first?.id == made?.id, "Volltextsuche findet sie")
        check((try? NoteAutomation.find("automatisch angelegt"))?.id == made?.id, "Finden über den Titel")
        check((try? NoteAutomation.find("gibt es nicht xyz")) == nil, "Unbekannte Notiz wird gemeldet")
        if let made {
            try? NoteAutomation.append("Angehängt per Automation", to: made)
            try? await Task.sleep(for: .seconds(0.5))
            let text = store.document(for: made.id).map { $0.blocks.map(\.plainText).joined() } ?? ((try? NoteFile.read(from: made.url))?.meta.searchText ?? "")
            check(text.contains("Angehängt per Automation") && text.contains("Zebra"), "Anhängen behält den Inhalt")
        }
        // Strict lookup and no change to what the user works on (#347).
        check((try? NoteAutomation.find("")) == nil && (try? NoteAutomation.find(UUID().uuidString)) == nil, "Leeres Ziel und unbekannte ID werden abgelehnt")
        let selected = store.selectedNoteID
        _ = try? NoteAutomation.create(title: "Im Hintergrund", text: "x")
        check(store.selectedNoteID == selected, "Anlegen per Automation wechselt die Auswahl nicht")
        _ = try? NoteAutomation.create(title: "Doppelt", text: "")
        _ = try? NoteAutomation.create(title: "Doppelt", text: "")
        check((try? NoteAutomation.find("Doppelt")) == nil, "Mehrdeutiger Titel wird abgelehnt")
        await intentChecks()
        await appleScriptChecks()
        print("AUTO done")
        fflush(stdout)
    }

    private static func intentChecks() async {
        var create = CreateNoteIntent()
        create.noteTitle = "Aus Kurzbefehl"
        create.text = "Giraffe"
        _ = try? await create.perform()
        check(NoteStore.shared.notes.contains { $0.meta.title == "Aus Kurzbefehl" }, "Kurzbefehl „Notiz erstellen“")
        let found = try? await NoteEntityQuery().entities(matching: "giraffe")
        check(found?.first?.title == "Aus Kurzbefehl", "Kurzbefehl-Suche nach Notizen")
    }

    /// Real Apple events to this process; needs the dictionary in the bundle (make-test-app copy).
    private static func appleScriptChecks() async {
        guard Bundle.main.url(forResource: "Folio", withExtension: "sdef") != nil, let id = Bundle.main.bundleIdentifier else {
            print("AUTO skip AppleScript (kein App-Paket mit Folio.sdef)")
            fflush(stdout)
            return
        }
        let script = """
            tell application id "\(id)"
                set newID to create note "Per AppleScript" with text "Okapi"
                set hits to search notes "okapi"
                append to note newID with text "Zweite Zeile"
                return (item 1 of hits) & "|" & newID
            end tell
            """
        let result: String? = await Task.detached {
            var error: NSDictionary?
            let out = NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error { return "ERROR \(error)" }
            return out?.stringValue
        }.value
        check(result?.hasPrefix("Per AppleScript|") == true, "AppleScript: anlegen, suchen, anhängen (\((result ?? "nil").replacingOccurrences(of: "\n", with: " ").prefix(300)))")
        let error: String? = await Task.detached {
            var error: NSDictionary?
            _ = NSAppleScript(source: "tell application id \"\(id)\" to open note \"gibt es wirklich nicht 123\"")?.executeAndReturnError(&error)
            return error?[NSAppleScript.errorMessage] as? String
        }.value
        check(error?.contains("Keine Notiz") == true, "AppleScript: Fehler bei unbekannter Notiz (\(error ?? "kein Fehler"))")
    }
}

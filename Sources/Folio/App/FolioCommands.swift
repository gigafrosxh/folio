import AppKit
import SwiftUI
import FolioCore

struct FolioCommands: Commands {
    @ObservedObject var store: NoteStore

    static func docs(_ path: String) -> URL {
        URL(string: "https://github.com/gigafrosxh/folio/blob/main/\(path)")!
    }
    @Environment(\.openWindow) private var openWindow
    private var f: FormattingController { .shared }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Nach Updates suchen …") { NotificationCenter.default.post(name: .folioShowUpdates, object: nil) }
        }
        CommandGroup(replacing: .newItem) {
            Button("Neue Notiz") { store.createNote() }
                .keyboardShortcut("n")
            Button("Neuer Ordner…") { NotificationCenter.default.post(name: .folioNewFolder, object: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Schnellerfassung …") { QuickCaptureController.shared.show() }
            Button("Tagesnotiz") { store.openDailyNote() }
                .keyboardShortcut("d", modifiers: [.command, .control])
            Button("Neuer Tab") { store.createNoteInNewTab() }
                .keyboardShortcut("t")
            Divider()
            Button("In neuem Fenster öffnen") { if let id = store.currentDocument?.id { openWindow(id: "note", value: id) } }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Button(store.splitNoteID == nil ? "Rechts daneben öffnen" : "Teilung schließen") {
                if store.splitNoteID != nil { store.splitNoteID = nil }
                else if let id = store.selectedNoteID { store.openInSplit(id) }
            }
            .keyboardShortcut("\\", modifiers: [.command, .option])
            // ⌘W itself closes the tab while several are open (ShortcutCenter, #107); the menu's ⌘W item stays „Schließen“.
            Button("Tab schließen (⌘W)") { if let id = store.selectedNoteID { store.closeTab(id) } }
            Button("Nächster Tab") { store.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Vorheriger Tab") { store.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            Button("Notiz duplizieren") { if let id = store.currentDocument?.id { store.duplicate(id) } }
                .keyboardShortcut("d")
            // Also reachable from the editor, not only with ⌫ in the note list (#108). No ⌘⌫: in text it deletes the line.
            Button("Notiz in den Papierkorb legen") { if let id = store.currentDocument?.id { store.delete(id) } }
            Divider()
            Button("Apple Notizen importieren…") { NotificationCenter.default.post(name: .folioShowImport, object: nil) }
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("In Notiz suchen …") { NotificationCenter.default.post(name: .folioFind, object: false) }
                .keyboardShortcut("f")
            Button("Suchen und ersetzen …") { NotificationCenter.default.post(name: .folioFind, object: true) }
                .keyboardShortcut("f", modifiers: [.command, .control])
            Button("Weitersuchen") { NotificationCenter.default.post(name: .folioFindNext, object: 1) }
                .keyboardShortcut("g")
            Button("Rückwärts suchen") { NotificationCenter.default.post(name: .folioFindNext, object: -1) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
        // Help with content instead of macOS' „Hilfe ist nicht verfügbar“ (#106).
        CommandGroup(replacing: .help) {
            Button("Folio-Hilfe") { NSWorkspace.shared.open(Self.docs("README.md")) }
                .keyboardShortcut("?", modifiers: .command)
            Button("Tastenkürzel …") {
                UserDefaults.standard.set("shortcuts", forKey: "folio.settingsTab")
                // Through the app menu's „Einstellungen …“ item, which also works when no window is key.
                if let appMenu = NSApp.mainMenu?.items.first?.submenu,
                   let i = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) { appMenu.performActionForItem(at: i) }
            }
            Button("Datenschutz und Sicherheit") { NSWorkspace.shared.open(Self.docs("docs/PRIVACY.md")) }
            Button("Änderungen in dieser Version") { NSWorkspace.shared.open(Self.docs("CHANGELOG.md")) }
            Divider()
            Button("Fehler melden oder Idee vorschlagen …") { NSWorkspace.shared.open(SettingsView.issuesURL) }
        }
        CommandGroup(after: .sidebar) {
            Button("Seitenleiste ein-/ausblenden") { NotificationCenter.default.post(name: .folioToggleSidebar, object: nil) }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Notizen durchsuchen") { NotificationCenter.default.post(name: .folioFocusSearch, object: nil) }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Fokusmodus") { NotificationCenter.default.post(name: .folioToggleFocus, object: nil) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Graph") { openWindow(id: "graph") }
                .keyboardShortcut("g", modifiers: [.command, .control])
            Button("Terminal ein-/ausblenden") { NotificationCenter.default.post(name: .folioToggleTerminal, object: nil) }
                .keyboardShortcut("`", modifiers: [.control])
            Button("Ausführungsumgebung der Notiz …") { NotificationCenter.default.post(name: .folioRunEnvironment, object: nil) }
        }
        // After "New": a .saveItem group disappears once the app has a second scene (note windows).
        CommandGroup(after: .newItem) {
            Button("Sichern") { store.currentDocument?.markDirty(); store.currentDocument?.saveNow() }
                .keyboardShortcut("s")
            Button("Schnell öffnen …") { NotificationCenter.default.post(name: .folioQuickOpen, object: QuickOpenMode.open) }
                .keyboardShortcut("p")
            Menu("Zuletzt geöffnet") {
                let store = NoteStore.shared
                ForEach(store.recent.ids.prefix(15).compactMap { id in store.notes.first { $0.id == id } }, id: \.id) { ref in
                    Button(ref.meta.title.isEmpty ? "Ohne Titel" : ref.meta.title) { store.open(noteID: ref.id) }
                }
            }
            Menu("Neu aus Vorlage") {
                let store = NoteStore.shared
                ForEach(store.templates, id: \.id) { t in
                    Button(t.meta.title) { store.createNote(from: t) }
                }
                Divider()
                Button("Vorlagen verwalten …") { store.ensureStarterTemplates(); store.sidebarSelection = .templates }
            }
            Button("Als Vorlage sichern") {
                if let doc = NoteStore.shared.currentDocument { NoteStore.shared.saveAsTemplate(doc) }
            }
            Divider()
            Button("Markdown importieren …") { MarkdownTransfer.importWithPanel() }
            Button("PDF importieren …") { PDFImport.importWithPanel() }
            Button("Als Markdown exportieren …") {
                if let doc = NoteStore.shared.currentDocument { MarkdownTransfer.exportWithPanel(doc) }
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
            Divider()
            Button("Versionsverlauf …") { NotificationCenter.default.post(name: .folioShowHistory, object: nil) }
                .keyboardShortcut("y", modifiers: [.command, .option])
            Button("Als PDF exportieren …") { NotificationCenter.default.post(name: .folioInsert, object: "exportpdf") }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandMenu("Format") {
            ForEach(TextStyle.allCases) { style in
                if let key = style.shortcut {
                    Button(style.label) { f.apply(style) }.keyboardShortcut(KeyEquivalent(key), modifiers: [.command, .shift])
                } else {
                    Button(style.label) { f.apply(style) }
                }
            }
            Divider()
            Button("Fett") { f.toggleBold() }.keyboardShortcut("b")
            Button("Kursiv") { f.toggleItalic() }.keyboardShortcut("i")
            Button("Unterstrichen") { f.toggleUnderline() }.keyboardShortcut("u")
            Button("Durchgestrichen") { f.toggleStrikethrough() }.keyboardShortcut("x", modifiers: [.command, .shift])
            Divider()
            Button("Checkliste") { f.toggleList(.checklist) }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Aufzählung") { f.toggleList(.bullet) }.keyboardShortcut("7", modifiers: [.command, .shift])
            Button("Nummerierte Liste") { f.toggleList(.numbered) }.keyboardShortcut("8", modifiers: [.command, .shift])
            Button("Einrücken") { f.indent(1) }.keyboardShortcut("]")
            Button("Ausrücken") { f.indent(-1) }.keyboardShortcut("[")
            Divider()
            Button("Link…") { NotificationCenter.default.post(name: .folioInsert, object: "link") }.keyboardShortcut("k")
            Button("Link zu Notiz …") { NotificationCenter.default.post(name: .folioQuickOpen, object: QuickOpenMode.link) }
                .keyboardShortcut("k", modifiers: [.command, .option])
            Button("Writing Tools …") { f.showWritingTools() }.keyboardShortcut("w", modifiers: [.command, .shift])
            Button("Chat mit Apple Intelligence") { NotificationCenter.default.post(name: .folioToggleChat, object: nil) }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Bibliothek fragen …") { NotificationCenter.default.post(name: .folioAskLibrary, object: nil) }
                .keyboardShortcut("i", modifiers: [.command, .option, .shift])
            Button("Schrift größer") { f.changeFontSize(by: 2) }.keyboardShortcut("+")
            Button("Schrift kleiner") { f.changeFontSize(by: -2) }.keyboardShortcut("-")
        }
        CommandMenu("Einfügen") {
            Button("Code-Block") { NotificationCenter.default.post(name: .folioInsert, object: "code") }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Numbers-Tabelle") { NotificationCenter.default.post(name: .folioInsert, object: "numbers") }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Datei, PDF oder Bild…") { NotificationCenter.default.post(name: .folioInsert, object: "file") }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Datenbank-Abfrage") { NotificationCenter.default.post(name: .folioInsert, object: "database") }
            Button("Formel (LaTeX)") { NotificationCenter.default.post(name: .folioInsert, object: "math") }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Button("Diagramm (Mermaid)") { NotificationCenter.default.post(name: .folioInsert, object: "diagram") }
                .keyboardShortcut("g", modifiers: [.command, .option])
            Button("Notiz einbetten …") { NotificationCenter.default.post(name: .folioQuickOpen, object: QuickOpenMode.embed) }
            Button("Audioaufnahme") { NotificationCenter.default.post(name: .folioInsert, object: "audio") }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Zeichnung") { NotificationCenter.default.post(name: .folioInsert, object: "drawing") }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Button("Skizze/Foto vom iPhone oder iPad…") { NotificationCenter.default.post(name: .folioInsert, object: "device") }
                .keyboardShortcut("d", modifiers: [.command, .option, .shift])
            // ⌥⌘W belongs to macOS ("Alle schließen").
            Button("Webseite…") { NotificationCenter.default.post(name: .folioInsert, object: "web") }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Bild mit Image Playground…") { NotificationCenter.default.post(name: .folioInsert, object: "playground") }
                .keyboardShortcut("p", modifiers: [.command, .option])
        }
    }
}

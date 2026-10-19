import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started as a bare binary (`swift run`); harmless inside the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        LayoutDebug.runIfRequested()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { NoteStore.shared.currentDocument?.saveNow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct FolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = NoteStore.shared
    @StateObject private var theme = ThemeManager.shared

    var body: some Scene {
        WindowGroup("Folio", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(theme)
                .preferredColorScheme(theme.settings.appearance.colorScheme)
                .tint(theme.accent)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .commands { FolioCommands(store: store) }

        Settings {
            SettingsView()
                .environmentObject(theme)
                .environmentObject(store)
                .preferredColorScheme(theme.settings.appearance.colorScheme)
                .tint(theme.accent)
        }
    }
}

struct FolioCommands: Commands {
    @ObservedObject var store: NoteStore
    private var f: FormattingController { .shared }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neue Notiz") { store.createNote() }
                .keyboardShortcut("n")
            Button("Neuer Ordner…") { NotificationCenter.default.post(name: .folioNewFolder, object: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Apple Notizen importieren…") { NotificationCenter.default.post(name: .folioShowImport, object: nil) }
        }
        CommandGroup(after: .sidebar) {
            Button("Seitenleiste ein-/ausblenden") { NotificationCenter.default.post(name: .folioToggleSidebar, object: nil) }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Notizen durchsuchen") { NotificationCenter.default.post(name: .folioFocusSearch, object: nil) }
                .keyboardShortcut("f", modifiers: [.command, .option])
        }
        CommandGroup(after: .saveItem) {
            Button("Sichern") { store.currentDocument?.markDirty(); store.currentDocument?.saveNow() }
                .keyboardShortcut("s")
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
            Button("Zeichnung") { NotificationCenter.default.post(name: .folioInsert, object: "drawing") }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Button("Skizze/Foto vom iPhone oder iPad…") { NotificationCenter.default.post(name: .folioInsert, object: "device") }
                .keyboardShortcut("d", modifiers: [.command, .option, .shift])
            Button("Webseite…") { NotificationCenter.default.post(name: .folioInsert, object: "web") }
                .keyboardShortcut("w", modifiers: [.command, .option])
            Button("Bild mit Image Playground…") { NotificationCenter.default.post(name: .folioInsert, object: "playground") }
                .keyboardShortcut("p", modifiers: [.command, .option])
        }
    }
}

/// Developer aid: `FOLIO_OPEN=<note path> FOLIO_LAYOUT_DUMP=1` opens a note and prints the frames of
/// its text views and embedded views, to diagnose overlapping blocks.
enum LayoutDebug {
    @MainActor static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let mode = env["FOLIO_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        }
        if let path = env["FOLIO_OPEN"] {
            let store = NoteStore.shared
            if let ref = store.notes.first(where: { $0.url.path == path }) { store.selectedNoteID = ref.id }
        }
        guard env["FOLIO_LAYOUT_DUMP"] != nil else { return }
        if let typed = env["FOLIO_TYPE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard let root = NSApp.windows.first(where: { $0.isVisible })?.contentView else { return }
                func find(_ v: NSView) -> FolioTextView? {
                    if let t = v as? FolioTextView, !t.string.isEmpty { return t }
                    for s in v.subviews { if let f = find(s) { return f } }
                    return nil
                }
                guard let tv = find(root) else { print("LAYOUT no text view"); return }
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                tv.insertNewline(nil)
                tv.insertText(typed, replacementRange: tv.selectedRange())
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard let root = NSApp.windows.first(where: { $0.isVisible })?.contentView else { return }
            func walk(_ v: NSView) {
                if v is FolioTextView || v is CodeTextView || String(describing: type(of: v)).contains("WKWebView")
                    || v is CodeEditorContainer {
                    let r = v.convert(v.bounds, to: nil)
                    var extra = ""
                    if let t = v as? FolioTextView { extra = "content=\(t.contentHeight(forWidth: t.bounds.width)) text=\(t.string.prefix(30).debugDescription)" }
                    print("LAYOUT", type(of: v), "y=\(Int(r.minY))..\(Int(r.maxY)) h=\(r.height) w=\(r.width)", extra)
                }
                v.subviews.forEach(walk)
            }
            walk(root)
            if let out = env["FOLIO_SNAPSHOT"], let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                print("LAYOUT snapshot", out)
            }
            fflush(stdout)
        }
    }
}

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
        MainActor.assumeIsolated {
            NoteStore.shared.currentDocument?.saveNow()
            RunManager.shared.stopAll()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// ⌘V when no text field has focus (e.g. right after picking a note in the list): the end of the
    /// responder chain lands here, and files or images go into the open note.
    @objc func paste(_ sender: Any?) {
        if ProcessInfo.processInfo.environment["FOLIO_LAYOUT_DUMP"] != nil { print("LAYOUT app delegate paste") }
        NotificationCenter.default.post(name: .folioPasteboard, object: NSPasteboard.general)
    }
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
                if typed == "run-server", let doc = NoteStore.shared.currentDocument {
                    let block = BlockModel(kind: .code)
                    block.language = "python"
                    block.storage.setAttributedString(NSAttributedString(string: "import http.server\nhttp.server.test(http.server.SimpleHTTPRequestHandler, port=8767, bind='127.0.0.1')"))
                    doc.insert(block, after: doc.blocks.first?.id)
                    RunManager.shared.start(block: block, doc: doc, theme: .shared)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { RunManager.shared.stopAll() }
                } else if typed.hasPrefix("list-paste") {
                    tv.window?.makeFirstResponder(nil)
                    if typed.hasPrefix("list-paste-file:") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([URL(fileURLWithPath: String(typed.dropFirst("list-paste-file:".count))) as NSURL])
                    } else if typed.hasPrefix("list-paste-image:") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([NSImage(contentsOfFile: String(typed.dropFirst("list-paste-image:".count)))!])
                    }
                    print("LAYOUT list paste target:", NSApp.target(forAction: #selector(NSText.paste(_:))).map { String(describing: type(of: $0)) } ?? "nil", "fr:", tv.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")
                    print("LAYOUT list paste sent:", NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil))
                } else if typed == "menu-paste" {
                    // Real ⌘V path: Edit › Paste through the responder chain with the general pasteboard.
                    print("LAYOUT menu paste sent:", NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil),
                          NSPasteboard.general.types ?? [])
                } else if typed.hasPrefix("paste-text:") {
                    let pb = NSPasteboard(name: NSPasteboard.Name("folio.debug"))
                    pb.clearContents()
                    pb.setString(String(typed.dropFirst("paste-text:".count)), forType: .string)
                    tv.insertNewline(nil)
                    print("LAYOUT paste text handled:", tv.handlePasteboard(pb))
                } else if typed.hasPrefix("paste-image:") || typed.hasPrefix("paste-file:") {
                    // Simulates ⌘V on a private pasteboard so the user's clipboard stays untouched.
                    let pb = NSPasteboard(name: NSPasteboard.Name("folio.debug"))
                    pb.clearContents()
                    let path = String(typed.drop(while: { $0 != ":" }).dropFirst())
                    if typed.hasPrefix("paste-image:"), let img = NSImage(contentsOfFile: path) {
                        pb.writeObjects([img])
                    } else {
                        pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
                    }
                    print("LAYOUT paste handled:", tv.handlePasteboard(pb), pb.types ?? [])
                } else {
                    tv.insertNewline(nil)
                    tv.insertText(typed, replacementRange: tv.selectedRange())
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (Double(env["FOLIO_DUMP_DELAY"] ?? "") ?? 4)) {
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
            if env["FOLIO_MENU_DUMP"] != nil, let menu = NSApp.mainMenu {
                for top in menu.items {
                    for item in top.submenu?.items ?? [] where !item.keyEquivalent.isEmpty {
                        print("MENU", top.title, "|", item.title, "|", item.keyEquivalent, item.keyEquivalentModifierMask.rawValue, "|", item.action.map(NSStringFromSelector) ?? "nil", "| target:", item.target.map { String(describing: type(of: $0)) } ?? "nil")
                    }
                }
                let fr = NSApp.keyWindow?.firstResponder
                print("MENU firstResponder", fr.map { String(describing: type(of: $0)) } ?? "nil")
                let pasteTarget = NSApp.target(forAction: #selector(NSText.paste(_:)))
                print("MENU paste target", pasteTarget.map { String(describing: type(of: $0)) } ?? "nil")
            }
            if let out = env["FOLIO_SNAPSHOT"], let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                print("LAYOUT snapshot", out)
            }
            fflush(stdout)
        }
    }
}

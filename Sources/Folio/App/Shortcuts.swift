import AppKit
import SwiftUI

/// A key plus modifiers, stored as text so it can live in the settings ("ctrl+c", "ctrl+shift+r").
struct KeyCombo: Codable, Hashable {
    /// Lowercased character, or a name: "space", "return", "tab", "delete", "escape", "up", "down", "left", "right", "f1"…
    var key: String
    var control = false
    var option = false
    var shift = false
    var command = false

    init(key: String, control: Bool = false, option: Bool = false, shift: Bool = false, command: Bool = false) {
        self.key = key
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
    }

    /// Reads a key press; nil for a press without any usable key (e.g. only modifiers).
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        control = flags.contains(.control)
        option = flags.contains(.option)
        shift = flags.contains(.shift)
        command = flags.contains(.command)
        switch event.keyCode {
        case 49: key = "space"
        case 36, 76: key = "return"
        case 48: key = "tab"
        case 51: key = "delete"
        case 53: key = "escape"
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        default:
            // With ⌃ the characters come back as control codes, so use the key without modifiers.
            if let chars = event.charactersIgnoringModifiers?.lowercased(), let first = chars.unicodeScalars.first,
               first.value >= 0x20, first.value != 0x7F {
                key = String(Character(first))
            } else if let letter = KeyCombo.ansiLetters[event.keyCode] {
                // Some sources deliver ⌃-letters as control characters; fall back to the physical key.
                key = letter
            } else {
                return nil
            }
        }
    }

    func matches(_ event: NSEvent) -> Bool { KeyCombo(event: event) == self }

    static let ansiLetters: [UInt16: String] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j", 40: "k", 37: "l", 46: "m",
        45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
    ]

    /// "⌃⇧C"
    var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        let names = ["space": "Leertaste", "return": "↩", "tab": "⇥", "delete": "⌫", "escape": "Esc",
                     "left": "←", "right": "→", "up": "↑", "down": "↓"]
        return s + (names[key] ?? key.uppercased())
    }

    /// Settings form: "ctrl+shift+c".
    var stored: String {
        var parts: [String] = []
        if control { parts.append("ctrl") }
        if option { parts.append("alt") }
        if shift { parts.append("shift") }
        if command { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    init?(stored: String) {
        let parts = stored.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.last, !last.isEmpty else { return nil }
        self.init(key: last, control: parts.contains("ctrl"), option: parts.contains("alt"),
                  shift: parts.contains("shift"), command: parts.contains("cmd"))
    }

    /// A shortcut needs ⌃, ⌥ or ⌘, otherwise it would swallow normal typing.
    var isUsable: Bool { control || option || command }
}

/// Tools that can be triggered from the keyboard; every one can be rebound in the settings.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case codeBlock, table, drawing, checklist, web, file, playground, link, chat, writingTools, runAll, database

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codeBlock: return "Code-Block einfügen"
        case .table: return "Numbers-Tabelle erstellen"
        case .drawing: return "Zeichnung einfügen"
        case .checklist: return "Checkliste"
        case .web: return "Webseite einbetten"
        case .file: return "Datei, PDF oder Bild einfügen"
        case .playground: return "Bild mit Image Playground"
        case .link: return "Link hinzufügen"
        case .chat: return "Chat mit Apple Intelligence"
        case .writingTools: return "Writing Tools"
        case .runAll: return "Alle Code-Blöcke ausführen"
        case .database: return "Datenbank-Abfrage einfügen"
        }
    }

    var icon: String {
        switch self {
        case .codeBlock: return "chevron.left.forwardslash.chevron.right"
        case .table: return "tablecells"
        case .drawing: return "scribble.variable"
        case .checklist: return "checklist"
        case .web: return "globe"
        case .file: return "paperclip"
        case .playground: return "apple.image.playground"
        case .link: return "link"
        case .chat: return "apple.intelligence"
        case .writingTools: return "apple.writing.tools"
        case .runAll: return "play.rectangle"
        case .database: return "cylinder.split.1x2"
        }
    }

    /// Defaults avoid the ⌃ keys macOS text fields use for cursor movement (⌃A, ⌃E, ⌃F, ⌃B, ⌃N, ⌃P, ⌃K, ⌃H …).
    var defaultCombo: KeyCombo {
        switch self {
        case .codeBlock: return KeyCombo(key: "c", control: true)
        case .table: return KeyCombo(key: "t", control: true)
        case .drawing: return KeyCombo(key: "d", control: true)
        case .checklist: return KeyCombo(key: "l", control: true)
        case .web: return KeyCombo(key: "w", control: true)
        case .file: return KeyCombo(key: "i", control: true)
        case .playground: return KeyCombo(key: "g", control: true)
        case .link: return KeyCombo(key: "u", control: true)
        case .chat: return KeyCombo(key: "j", control: true)
        case .writingTools: return KeyCombo(key: "r", control: true)
        case .runAll: return KeyCombo(key: "r", control: true, shift: true)
        case .database: return KeyCombo(key: "d", control: true, shift: true)
        }
    }
}

/// Built-in shortcuts that are not rebindable, for the cheat sheet.
enum FixedShortcuts {
    static let groups: [(title: String, items: [(String, String)])] = [
        ("Code-Blöcke", [
            ("⇧↩ oder ⌘↩", "Code-Block ausführen"),
            ("⌃C (während Code läuft)", "Ausführung stoppen"),
            ("⌥⇧F", "Code formatieren"),
            ("⌃Leertaste", "Vorschlagsliste öffnen"),
            ("Tab / ↩", "Vorschlag übernehmen"),
            ("Esc", "Vorschlag oder Liste schließen"),
            ("⇥ / ⇧⇥", "Einrücken / Ausrücken"),
        ]),
        ("Text", [
            ("⌘B / ⌘I / ⌘U", "Fett / Kursiv / Unterstrichen"),
            ("⇧⌘X", "Durchgestrichen"),
            ("⇧⌘1 / 2 / 3 / 0", "Titel / Überschrift / Unterüberschrift / Text"),
            ("⇧⌘7 / ⇧⌘8", "Aufzählung / Nummerierte Liste"),
            ("⌘K", "Link"),
            ("⇧⌘W", "Writing Tools"),
            ("Tab", "Textvorschlag übernehmen"),
        ]),
        ("Notizen & Fenster", [
            ("⌘N / ⇧⌘N", "Neue Notiz / Neuer Ordner"),
            ("⌥⌘S", "Seitenleiste ein-/ausblenden"),
            ("⌥⌘F", "Notizen durchsuchen"),
            ("⌥⌘I", "Chat mit Apple Intelligence"),
            ("⌘,", "Einstellungen"),
        ]),
    ]
}

/// Listens for the tool shortcuts anywhere in the main window and runs the matching tool.
@MainActor
final class ShortcutCenter {
    static let shared = ShortcutCenter()
    private var monitor: Any?
    /// Set while the settings record a new shortcut, so the key press isn't executed.
    var isRecording = false

    func combo(for action: ShortcutAction) -> KeyCombo {
        ThemeManager.shared.settings.shortcuts[action.rawValue].flatMap(KeyCombo.init(stored:)) ?? action.defaultCombo
    }

    func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        ThemeManager.shared.settings.shortcuts[action.rawValue] = combo?.stored
    }

    /// Actions currently bound to `combo` (to warn about duplicates).
    func actions(using combo: KeyCombo) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { self.combo(for: $0) == combo }
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.isRecording else { return event }
            return MainActor.assumeIsolated { self.handle(event) ? nil : event }
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        if ProcessInfo.processInfo.environment["FOLIO_LAYOUT_DUMP"] != nil {
            print("LAYOUT key event", KeyCombo(event: event)?.display ?? "?", "window:", event.window?.identifier?.rawValue ?? "nil", "key:", event.window?.isKeyWindow ?? false)
        }
        // Only in the note window (not in Settings, sheets or the completion list).
        guard let window = event.window, window.isKeyWindow, !(window is NSPanel),
              window.identifier?.rawValue.hasPrefix("main") == true, window.attachedSheet == nil else { return false }
        // ⌃C inside a running code block stops it, like in a terminal.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control, event.charactersIgnoringModifiers == "c",
           let code = window.firstResponder as? CodeTextView, let id = code.blockID, RunManager.shared.isRunning(id) {
            RunManager.shared.stop(id)
            return true
        }
        guard let action = ShortcutAction.allCases.first(where: { combo(for: $0).matches(event) }) else { return false }
        perform(action)
        return true
    }

    func perform(_ action: ShortcutAction) {
        let f = FormattingController.shared
        switch action {
        case .codeBlock: post("code")
        case .table: post("numbers")
        case .drawing: post("drawing")
        case .checklist: f.toggleList(.checklist)
        case .web: post("web")
        case .file: post("file")
        case .playground: post("playground")
        case .link: post("link")
        case .chat: NotificationCenter.default.post(name: .folioToggleChat, object: nil)
        case .writingTools: f.showWritingTools()
        case .runAll: post("runall")
        case .database: post("database")
        }
    }

    private func post(_ kind: String) { NotificationCenter.default.post(name: .folioInsert, object: kind) }
}

import AppKit
import FolioCore

/// #59: keyboard control end to end. Real key events go through the app (menus and Folio's own tool
/// shortcuts) and the effect is checked: FOLIO_KEY_TEST=1 with a throwaway FOLIO_LIBRARY.
@MainActor
enum KeyboardSelfTest {
    private static func check(_ ok: Bool, _ label: String) {
        print(ok ? "KEY ok" : "KEY FAIL", label)
        fflush(stdout)
    }

    private static func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    /// German keyboard layout key codes for the keys used below.
    private static let codes: [String: UInt16] = ["n": 45, "t": 17, "d": 2, "f": 3, "p": 35, "s": 1, "y": 6, "c": 8, "k": 40, "g": 5, "ä": 39, "ö": 41, "\u{1b}": 53]

    private static func press(_ key: String, _ mods: NSEvent.ModifierFlags) async {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Like a real keyboard: shift gives the capital letter, control gives a control character.
        let shifted = mods.contains(.shift) ? key.uppercased() : key
        let chars = mods.contains(.control) ? String(UnicodeScalar(UInt8(key.unicodeScalars.first!.value & 0x1F))) : shifted
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: key, isARepeat: false, keyCode: codes[key] ?? 0) else { return }
        if mods.contains(.shift), key.first?.isLetter == true, key.count == 1, "äöü".contains(key) == false,
           let (menu, index) = menuItem(key, mods) {
            // Synthesized ⇧+letter events are matched by AppKit but SwiftUI does not run the action for them
            // (also for ⇧⌘N, which works with a real keyboard), so the menu item bound to the key runs directly.
            menu.performActionForItem(at: index)
        } else {
            // Through the event queue, so menus and Folio's key monitor see it exactly like a key press.
            NSApp.postEvent(event, atStart: false)
        }
        await wait(0.4)
    }

    /// The menu item a shortcut is bound to.
    private static func menuItem(_ key: String, _ mods: NSEvent.ModifierFlags) -> (NSMenu, Int)? {
        func find(_ m: NSMenu?) -> (NSMenu, Int)? {
            guard let m else { return nil }
            for (i, item) in m.items.enumerated() {
                if item.keyEquivalent.lowercased() == key.lowercased(),
                   item.keyEquivalentModifierMask == mods.intersection([.command, .shift, .option, .control]) { return (m, i) }
                if let f = find(item.submenu) { return f }
            }
            return nil
        }
        return find(NSApp.mainMenu)
    }

    private final class Seen: @unchecked Sendable { var names: Set<String> = [] }

    static func run() async {
        let store = NoteStore.shared
        await wait(2)
        let seen = Seen()
        for name in [Notification.Name.folioFind, .folioQuickOpen, .folioShowHistory, .folioToggleFocus, .folioNewFolder] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { n in seen.names.insert(n.name.rawValue) }
        }

        // Every menu shortcut is used once.
        var combos: [String: [String]] = [:]
        for top in NSApp.mainMenu?.items ?? [] {
            func walk(_ menu: NSMenu?) {
                for item in menu?.items ?? [] {
                    if !item.keyEquivalent.isEmpty {
                        combos["\(item.keyEquivalent.lowercased())|\(item.keyEquivalentModifierMask.rawValue)", default: []].append(item.title)
                    }
                    walk(item.submenu)
                }
            }
            walk(top.submenu)
        }
        let dups = combos.filter { $0.value.count > 1 }
        check(dups.isEmpty, "Keine doppelt belegten Menükürzel \(dups.isEmpty ? "" : "\(dups.values)")")

        let before = store.notes.count
        await press("n", .command)
        check(store.notes.count == before + 1, "⌘N legt eine Notiz an")
        await press("t", .command)
        check(store.tabs.count == 2, "⌘T öffnet einen neuen Tab (\(store.tabs.count))")
        let active = store.selectedNoteID
        await press("ö", [.command, .shift])
        check(store.selectedNoteID != active, "⇧⌘[ wechselt den Tab")
        await press("ä", [.command, .shift])
        check(store.selectedNoteID == active, "⇧⌘] wechselt zurück")
        let count = store.notes.count
        await press("d", .command)
        check(store.notes.count == count + 1 && store.notes.contains { $0.meta.title.hasSuffix("Kopie") }, "⌘D dupliziert die Notiz")

        await press("f", .command)
        check(seen.names.contains(Notification.Name.folioFind.rawValue), "⌘F öffnet die Suche in der Notiz")
        await press("p", .command)
        check(seen.names.contains(Notification.Name.folioQuickOpen.rawValue), "⌘P öffnet Schnell öffnen")
        await press("\u{1b}", [])
        await press("y", [.command, .option])
        check(seen.names.contains(Notification.Name.folioShowHistory.rawValue), "⌥⌘Y öffnet den Versionsverlauf")

        let sidebar = UserDefaults.standard.object(forKey: "folio.sidebarVisible") as? Bool ?? true
        await press("s", [.command, .option])
        check((UserDefaults.standard.object(forKey: "folio.sidebarVisible") as? Bool ?? true) != sidebar, "⌥⌘S blendet die Seitenleiste um")
        await press("s", [.command, .option])

        // While writing (cursor in the note).
        if let doc = store.currentDocument, let first = doc.blocks.first {
            FormattingController.shared.focus(blockID: first.id)
            await wait(0.3)
        }
        UserDefaults.standard.set(false, forKey: "folio.focusMode")
        await press("f", [.command, .shift])
        check(UserDefaults.standard.bool(forKey: "folio.focusMode"), "⇧⌘F schaltet den Fokusmodus ein")
        await press("f", [.command, .shift])
        check(!UserDefaults.standard.bool(forKey: "folio.focusMode"), "⇧⌘F schaltet ihn wieder aus")

        // Folio's own tool shortcut (⌃C inserts a code block).
        if let doc = store.currentDocument, NSApp.isActive {
            let blocks = doc.blocks.count
            FormattingController.shared.focus(blockID: doc.blocks[0].id)
            await wait(0.3)
            await press("c", .control)
            check(doc.blocks.contains { $0.kind == .code } && doc.blocks.count > blocks, "⌃C fügt einen Code-Block ein")
        } else {
            // Tool shortcuts only act in the key window of the active app; a test started in the background skips this.
            print("KEY skip ⌃C (Folio ist nicht die aktive App)")
        }
        print("KEY done"); fflush(stdout)
    }
}

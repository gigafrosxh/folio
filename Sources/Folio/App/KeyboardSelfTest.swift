import AppKit
import FolioCore

/// #59: keyboard control end to end. Real key events go through the app (menus and Folio's own tool
/// shortcuts) and the effect is checked: FOLIO_KEY_TEST=1 with a throwaway FOLIO_LIBRARY.
@MainActor
enum KeyboardSelfTest {
    private static func hardwareKeyDowns() -> UInt32 { CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown) }
    private static var keyDownsSeen = hardwareKeyDowns()
    private static var lostActivation = false
    /// Checks that could not run; a run with any of them is incomplete, not passed (#157).
    private static var skipped = 0

    /// Someone typing on the real keyboard or switching apps during a check says nothing about Folio (#135).
    private static func check(_ ok: Bool, _ label: String) {
        let disturbed = lostActivation || hardwareKeyDowns() != keyDownsSeen
        if !ok && disturbed { skipped += 1 }
        print(ok ? "KEY ok" : disturbed ? "KEY skip (gestört durch echte Eingabe oder App-Wechsel)" : "KEY FAIL", label)
        fflush(stdout)
        keyDownsSeen = hardwareKeyDowns()
        lostActivation = false
    }

    private static func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    /// Waits for an effect instead of guessing how long it takes; a release build has different timing (#135).
    private static func waitUntil(_ seconds: Double = 2, _ condition: () -> Bool) async {
        var left = seconds
        while !condition(), left > 0 {
            await wait(0.05)
            left -= 0.05
        }
    }

    /// German keyboard layout key codes for the keys used below.
    private static let codes: [String: UInt16] = ["w": 13, "n": 45, "t": 17, "d": 2, "f": 3, "p": 35, "s": 1, "y": 6, "c": 8, "k": 40, "g": 5, "ä": 39, "ö": 41, "\u{1b}": 53]

    private static func press(_ key: String, _ mods: NSEvent.ModifierFlags, settle: Double = 0.4) async {
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
        if settle > 0 { await wait(settle) }
    }

    /// Esc in whatever window is key (a sheet), like closing it with the keyboard.
    private static func escapeInKeyWindow() async {
        guard let w = NSApp.keyWindow,
              let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                       isARepeat: false, keyCode: 53) else { return }
        NSApp.postEvent(e, atStart: false)
        await wait(0.5)
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

    /// Every menu shortcut with the items using it.
    private static func menuShortcuts() -> [String: [String]] {
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
        return combos
    }

    private final class Seen: @unchecked Sendable { var names: Set<String> = [] }

    static func run() async {
        let store = NoteStore.shared
        await wait(2)
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { lostActivation = true }
        }
        let seen = Seen()
        for name in [Notification.Name.folioFind, .folioQuickOpen, .folioShowHistory, .folioToggleFocus, .folioNewFolder] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { n in seen.names.insert(n.name.rawValue) }
        }

        let combos = menuShortcuts()
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
        // Close the version history sheet again, otherwise the main window is not key for the next checks.
        await escapeInKeyWindow()

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
            await waitUntil { doc.blocks.contains { $0.kind == .code } && doc.blocks.count > blocks }
            check(doc.blocks.contains { $0.kind == .code } && doc.blocks.count > blocks, "⌃C fügt einen Code-Block ein")
        } else {
            // Tool shortcuts only act in the key window of the active app; a test started in the background skips this.
            skipped += 1
            print("KEY skip ⌃C (Folio ist nicht die aktive App)")
        }
        await focusChecks(store)
        await closeTabCheck(store)
        await trashMenuCheck(store)
        await helpMenuCheck()
        if skipped > 0 { print("KEY FAIL Unvollständig: \(skipped) Prüfungen übersprungen") }
        print("KEY done"); fflush(stdout)
    }

    /// ⌘W closes a tab while several are open, and not the window (#107).
    private static func closeTabCheck(_ store: NoteStore) async {
        guard NSApp.isActive else { return }
        await press("t", .command)
        let tabs = store.tabs.count
        await press("w", .command)
        let window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
        check(tabs > 1 && store.tabs.count == tabs - 1 && window != nil, "⌘W schließt bei mehreren Tabs nur den Tab (#107: \(tabs) → \(store.tabs.count))")
    }

    /// „Ablage → Notiz in den Papierkorb legen“ works from the editor (#108).
    private static func trashMenuCheck(_ store: NoteStore) async {
        guard let id = store.currentDocument?.id else { return }
        let count = store.notes.count
        var found: (NSMenu, Int)?
        for top in NSApp.mainMenu?.items ?? [] {
            if let m = top.submenu, let i = m.items.firstIndex(where: { $0.title == "Notiz in den Papierkorb legen" }) { found = (m, i) }
        }
        found.map { $0.0.performActionForItem(at: $0.1) }
        await wait(0.5)
        check(found != nil && store.notes.count == count - 1 && !store.notes.contains { $0.id == id },
              "Menü „Notiz in den Papierkorb legen“ legt die offene Notiz in den Papierkorb (#108)")
    }

    /// The Help menu has content and opens the shortcut settings (#106).
    private static func helpMenuCheck() async {
        guard let help = NSApp.mainMenu?.items.last?.submenu else { check(false, "Hilfe-Menü"); return }
        let titles = help.items.map(\.title)
        check(titles.contains("Folio-Hilfe") && !titles.contains("Toggle Sidebar"), "Hilfe-Menü ohne englischen Resteintrag (#106: \(titles.filter { !$0.isEmpty }))")
        if let i = help.items.firstIndex(where: { $0.title == "Tastenkürzel …" }) { help.performActionForItem(at: i) }
        await wait(1.5)
        let settings = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }
        check(settings?.title == "Tastenkürzel", "„Hilfe → Tastenkürzel …“ öffnet die Einstellungen beim Reiter Tastenkürzel (\(settings?.title ?? "-"))")
        settings?.close()
    }

    /// Plain typing posted right away, like a fast typist after a shortcut.
    private static func typeNow(_ text: String) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) else { return }
        for ch in text {
            let s = String(ch)
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: s, charactersIgnoringModifiers: s,
                                           isARepeat: false, keyCode: 0) else { continue }
            NSApp.postEvent(e, atStart: false)
        }
    }

    private static func noteText(_ store: NoteStore) -> String {
        store.currentDocument?.blocks.map(\.storage.string).joined(separator: "\n") ?? ""
    }

    /// Focus after shortcuts: new note during a search (#100, #102) and the quick switcher (#99).
    private static func focusChecks(_ store: NoteStore) async {
        guard NSApp.isActive else {
            skipped += 1
            print("KEY skip Fokusprüfung (Folio ist nicht die aktive App)")
            return
        }
        store.searchText = "zzzzkeinTreffer"
        await wait(0.3)
        await press("n", .command)
        check(store.searchText.isEmpty && store.filteredNotes.contains { $0.id == store.selectedNoteID },
              "Neue Notiz bei aktiver Suche ist in der Liste sichtbar (#102)")

        let before = store.notes.count
        let window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
        if let window, let first = store.currentDocument?.blocks.first, let tv = FormattingController.shared.textView(for: first.id) {
            window.makeFirstResponder(tv)   // typing goes somewhere else before ⌘N
        }
        await press("n", .command, settle: 0)
        typeNow("Schnell")
        await wait(1.5)
        check(store.notes.count == before + 1 && noteText(store).hasPrefix("Schnell"),
              "Direkt nach ⌘N Getipptes landet in der neuen Notiz (#100: „\(noteText(store).prefix(20))“)")

        let text = noteText(store)
        if let first = store.currentDocument?.blocks.first { FormattingController.shared.focus(blockID: first.id) }
        await wait(0.3)
        await press("p", .command, settle: 0)
        typeNow("xyz")
        await waitUntil { (NSApp.keyWindow?.firstResponder as? NSTextView)?.string == "xyz" }
        let responder = NSApp.keyWindow?.firstResponder as? NSTextView
        check(noteText(store) == text && responder?.isFieldEditor == true && responder?.string == "xyz",
              "⌘P: Getipptes geht in den Schnellwechsel, nicht in die Notiz (#99: \"\(responder?.string ?? "-")\")")
        await press("\u{1b}", [])
        await quickOpenTimingChecks(store)
    }

    /// #135: keys at any distance after ⌘P, also posted in the same event-loop turn, must never reach the note.
    private static func quickOpenTimingChecks(_ store: NoteStore) async {
        let rounds = Int(ProcessInfo.processInfo.environment["FOLIO_KEY_ROUNDS"] ?? "") ?? 1
        for gap in [0, 0.001, 0.005, 0.02, 0.05, 0.12, 0.3] {
            for round in 0..<rounds { await quickOpenRound(store, gap: gap, round: round) }
        }
    }

    private static func quickOpenRound(_ store: NoteStore, gap: Double, round: Int) async {
        guard let first = store.currentDocument?.blocks.first else { return }
        FormattingController.shared.focus(blockID: first.id)
        await wait(0.3)
        let text = noteText(store)
        await press("p", .command, settle: 0)
        if gap > 0 { await wait(gap) }
        typeNow("q")
        if gap > 0 { await wait(gap) }
        typeNow("rs")
        await waitUntil { (NSApp.keyWindow?.firstResponder as? NSTextView)?.string == "qrs" }
        let responder = NSApp.keyWindow?.firstResponder as? NSTextView
        let unchanged = noteText(store) == text
        check(unchanged && responder?.isFieldEditor == true && responder?.string == "qrs",
              "⌘P, Abstand \(gap) s, Runde \(round): Feld „\(responder?.string ?? "-")“, Notiz \(unchanged ? "unverändert" : "GEÄNDERT: \(noteText(store).suffix(12))")")
        await press("\u{1b}", [])
    }
}

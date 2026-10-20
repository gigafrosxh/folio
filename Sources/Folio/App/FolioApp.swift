import AppKit
import SwiftUI
import FolioCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started as a bare binary (`swift run`); harmless inside the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        ShortcutCenter.shared.install()
        // Test runs against a throwaway library never ask for updates: the sheet would take the keyboard.
        if ThemeManager.shared.settings.askForUpdatesOnLaunch, ProcessInfo.processInfo.environment["FOLIO_LIBRARY"] == nil {
            // Quietly; the sheet only appears when an update is actually available.
            MainActor.assumeIsolated { UpdateManager.shared.check(silently: true) }
        }
        LayoutDebug.runIfRequested()
        MainActor.assumeIsolated {
            BackupManager.shared.start()
            CaptureService.shared.start()
            QuickAccessSettings.apply()
        }
        // Load the on-device model in the background so the first suggestion comes quickly.
        if ThemeManager.shared.settings.aiPredictions { TextPredictor.prewarm() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            // An unanswered conflict on quit: keep both versions rather than lose either.
            if let conflict = NoteStore.shared.conflict { NoteStore.shared.resolve(conflict, .keepBoth) }
            NoteStore.shared.saveAll()
            TerminalSession.closeAll()
            RunManager.shared.stopAll()
            LSPCompleter.shared.shutdownAll()
            KernelManager.shared.shutdownAll()
        }
    }

    /// folio:// links from other apps, Shortcuts or the browser (#89).
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { DeepLinks.handle(url) }
        }
    }

    /// With the menu bar icon Folio keeps running when the last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !ThemeManager.shared.settings.menuBarIcon }
    }

    /// Clicking the Dock icon with no window open brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { QuickAccessSettings.showMainWindow(QuickAccessSettings.opener) } }
        return true
    }

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

        // A note in its own window (Ablage › In neuem Fenster öffnen).
        WindowGroup("Notiz", id: "note", for: UUID.self) { $id in
            NoteWindowView(noteID: id)
                .environmentObject(store)
                .environmentObject(theme)
                .preferredColorScheme(theme.settings.appearance.colorScheme)
                .tint(theme.accent)
        }
        .defaultSize(width: 760, height: 820)

        // Menu bar icon (#85), optional in Settings › Schnellzugriff.
        MenuBarExtra("Folio", systemImage: "note.text", isInserted: Binding(
            get: { theme.settings.menuBarIcon }, set: { v in if theme.settings.menuBarIcon != v { theme.settings.menuBarIcon = v } })) {
            MenuBarPanel()
                .environmentObject(store)
                .environmentObject(theme)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(theme)
                .environmentObject(store)
                .preferredColorScheme(theme.settings.appearance.colorScheme)
                .tint(theme.accent)
        }
    }
}

#if os(iOS)
    import SwiftUI
    import FolioCore

    /// Folio for iPad (#214): the same `.folio` library format as the Mac, with sidebar, note list and editor.
    @main
    struct FolioPadApp: App {
        @StateObject private var library = PadLibrary()

        var body: some Scene {
            WindowGroup {
                PadRootView()
                    .environmentObject(library)
            }
            .commands { PadCommands(library: library) }
        }
    }

    /// Keyboard shortcuts as on the Mac (⌘N, ⌘F, ⌘S, ⌘⌫), shown in the iPad's ⌘ overlay.
    struct PadCommands: Commands {
        @ObservedObject var library: PadLibrary

        var body: some Commands {
            CommandGroup(replacing: .newItem) {
                Button("Neue Notiz") { library.createNote() }.keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("Sichern") { library.saveNow() }.keyboardShortcut("s")
                Button("Notiz in den Papierkorb") { library.trashSelected() }.keyboardShortcut(.delete)
                    .disabled(library.selectedNote == nil)
            }
            CommandGroup(after: .textEditing) {
                Button("Notizen durchsuchen") { library.focusSearch.toggle() }.keyboardShortcut("f")
            }
        }
    }
#else
    /// FolioPad is an iPadOS app; on macOS this target only builds so `swift build` covers it.
    @main
    enum FolioPadUnavailable {
        static func main() { print("FolioPad läuft nur auf iPadOS (scripts/build-ipad.sh).") }
    }
#endif

import AppKit
import ImagePlayground
import SwiftUI
import UniformTypeIdentifiers
import FolioCore

/// Terminal and run-environment commands of one editor (kept apart so the editor body type-checks quickly).
struct DeveloperPanels: ViewModifier {
    @ObservedObject var doc: NoteDocument
    var isActive: Bool
    @Binding var showTerminal: Bool
    @Binding var showEnvironment: Bool
    @EnvironmentObject var theme: ThemeManager

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showEnvironment) { RunEnvironmentSheet(doc: doc).environmentObject(theme) }
            .onReceive(NotificationCenter.default.publisher(for: .folioToggleTerminal)) { _ in
                if isActive { withAnimation(Motion.quick) { showTerminal.toggle() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .folioShowTerminal)) { note in
                if (note.object as? UUID) == doc.id { withAnimation(Motion.quick) { showTerminal = true } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .folioRunEnvironment)) { _ in if isActive { showEnvironment = true } }
            .animation(Motion.quick, value: showTerminal)
    }
}

/// Callbacks the toolbar and blocks use to insert content.
struct EditorActions {
    var insertCode: (String) -> Void
    var insertFile: () -> Void
    var insertNumbers: () -> Void
    var insertWeb: () -> Void
    var insertImagePlayground: () -> Void
    var insertDrawing: () -> Void
    var importFromDevice: () -> Void
    var addLink: () -> Void
    var pasteFiles: ([URL], UUID) -> Bool
    var pasteImage: (Data, UUID) -> Void
    var pasteURL: (URL, UUID) -> Bool
}

extension Notification.Name {
    /// Posted by menu commands; `object` is the kind of block to insert.
    static let folioInsert = Notification.Name("folio.insert")
    /// Opens the chat of the focused note (without toggling it closed).
    static let folioOpenChat = Notification.Name("folio.openChat")
    /// Opens the chat in "whole library" mode.
    static let folioAskLibrary = Notification.Name("folio.askLibrary")
    /// Shows or hides the focused note's terminal panel.
    static let folioToggleTerminal = Notification.Name("folio.toggleTerminal")
    /// Shows the terminal of the note whose id is `object`.
    static let folioShowTerminal = Notification.Name("folio.showTerminal")
    /// Opens the run environment settings of the focused note.
    static let folioRunEnvironment = Notification.Name("folio.runEnvironment")
    /// Opens the quick-open panel; `object` is a `QuickOpenMode`.
    static let folioQuickOpen = Notification.Name("folio.quickOpen")
    /// Opens the version history of the open note.
    static let folioShowHistory = Notification.Name("folio.showHistory")
    /// Shows or hides the Apple Intelligence chat panel.
    static let folioToggleChat = Notification.Name("folio.toggleChat")
    /// Posted with the pasteboard when ⌘V reaches the app without a text field handling it.
    static let folioPasteboard = Notification.Name("folio.pasteboard")
}

import AppKit
import SwiftUI
import FolioCore

/// Carries out folio:// links (#89) after validating them; problems are shown, nothing is changed then.
@MainActor
enum DeepLinks {
    static func handle(_ url: URL) {
        switch FolioURL.parse(url) {
        case .failure(let error):
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Dieser Folio-Link funktioniert nicht"
            alert.informativeText = "\(error.localizedDescription)\n\n\(url.absoluteString.prefix(300))"
            alert.runModal()
        case .success(let action):
            perform(action)
        }
    }

    static func perform(_ action: FolioAction) {
        switch action {
        case .openNote(let id, let passage): openNote(id, passage: passage)
        case .capture(let text, let target): capture(text, target: target)
        case .search(let q): search(q)
        case .newNote(let title, let text): newNote(title: title, text: text)
        case .open: QuickAccessSettings.showMainWindow(QuickAccessSettings.opener)
        }
    }

    /// A note that is gone is reported; the passage, when given, is shown once the note is open.
    private static func openNote(_ id: UUID, passage: Int?) {
        let store = NoteStore.shared
        QuickAccessSettings.showMainWindow(QuickAccessSettings.opener)
        guard let ref = store.notes.first(where: { $0.id == id }) else {
            store.lastError = "Die verlinkte Notiz gibt es in dieser Bibliothek nicht (mehr)."
            return
        }
        store.open(noteID: id)
        guard let passage, let p = Passages.split(noteID: id, title: ref.meta.title, text: ref.meta.searchText).first(where: { $0.index == passage }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NotificationCenter.default.post(name: .folioRevealText, object: RevealRequest(noteID: id, text: p.text))
        }
    }

    /// An unknown target note falls back to the inbox, with a note in the window.
    private static func capture(_ text: String?, target: CaptureTarget?) {
        guard case .note(let id) = target, !NoteStore.shared.notes.contains(where: { $0.id == id }) else {
            QuickCaptureController.shared.show(text: text, target: target)
            return
        }
        QuickCaptureController.shared.show(text: text, target: .inbox)
        QuickCaptureController.shared.model.status = (false, "Die Zielnotiz aus dem Link gibt es nicht; die Erfassung geht in die Inbox.")
    }

    private static func search(_ q: String) {
        QuickAccessSettings.showMainWindow(QuickAccessSettings.opener)
        NoteStore.shared.sidebarSelection = .all
        NoteStore.shared.searchText = q
    }

    private static func newNote(title: String?, text: String?) {
        let store = NoteStore.shared
        QuickAccessSettings.showMainWindow(QuickAccessSettings.opener)
        guard store.createNote() != nil, let doc = store.currentDocument else { return }
        let theme = ThemeManager.shared
        let s = NSMutableAttributedString()
        if let title { s.append(NSAttributedString(string: title, attributes: TextStyle.title.attributes(theme: theme))) }
        if let text { s.append(NSAttributedString(string: (title == nil ? "" : "\n") + text, attributes: theme.bodyAttributes)) }
        guard s.length > 0 else { return }
        doc.blocks[0].storage.setAttributedString(s)
        doc.markDirty()
    }
}

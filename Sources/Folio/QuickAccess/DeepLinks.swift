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
        let store = NoteStore.shared
        switch action {
        case .openNote(let id, let passage):
            guard store.notes.contains(where: { $0.id == id }) else {
                QuickAccessSettings.showMainWindow(QuickAccessSettings.opener)
                store.lastError = "Die verlinkte Notiz gibt es in dieser Bibliothek nicht (mehr)."
                return
            }
            QuickAccessSettings.showMainWindow(QuickAccessSettings.opener)
            store.open(noteID: id)
            if let passage, let ref = store.notes.first(where: { $0.id == id }) {
                let parts = Passages.split(noteID: id, title: ref.meta.title, text: ref.meta.searchText)
                if let p = parts.first(where: { $0.index == passage }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        NotificationCenter.default.post(name: .folioRevealText, object: RevealRequest(noteID: id, text: p.text))
                    }
                }
            }
        case .capture(let text, let target):
            if case .note(let id) = target, !store.notes.contains(where: { $0.id == id }) {
                QuickCaptureController.shared.show(text: text, target: .inbox)
                QuickCaptureController.shared.model.status = (false, "Die Zielnotiz aus dem Link gibt es nicht; die Erfassung geht in die Inbox.")
                return
            }
            QuickCaptureController.shared.show(text: text, target: target)
        case .search(let q):
            QuickAccessSettings.showMainWindow(QuickAccessSettings.opener)
            store.sidebarSelection = .all
            store.searchText = q
        case .newNote(let title, let text):
            QuickAccessSettings.showMainWindow(QuickAccessSettings.opener)
            guard store.createNote() != nil, let doc = store.currentDocument else { return }
            let body = ThemeManager.shared.bodyAttributes
            let s = NSMutableAttributedString()
            if let title { s.append(NSAttributedString(string: title, attributes: TextStyle.title.attributes(theme: ThemeManager.shared))) }
            if let text { s.append(NSAttributedString(string: (title == nil ? "" : "\n") + text, attributes: body)) }
            if s.length > 0 {
                doc.blocks[0].storage.setAttributedString(s)
                doc.markDirty()
            }
        case .open:
            QuickAccessSettings.showMainWindow(QuickAccessSettings.opener)
        }
    }
}

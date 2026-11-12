import AppKit

/// The question before quitting while notes cannot be saved (#189).
@MainActor
enum UnsavedOnQuit {
    enum Answer { case retry, cancel, quitAnyway }

    static func ask(_ docs: [NoteDocument]) -> Answer {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = docs.count == 1 ? "Eine Notiz konnte nicht gesichert werden" : "\(docs.count) Notizen konnten nicht gesichert werden"
        alert.informativeText = "\(NoteStore.titles(docs)) hat Änderungen, die nicht gespeichert werden konnten "
            + "(zum Beispiel weil der Ordner gesperrt oder der Datenträger voll ist). Wenn du jetzt beendest, gehen sie verloren."
        alert.addButton(withTitle: "Nicht beenden")
        alert.addButton(withTitle: "Erneut versuchen")
        alert.addButton(withTitle: "Trotzdem beenden").hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .cancel
        case .alertSecondButtonReturn: return .retry
        default: return .quitAnyway
        }
    }
}

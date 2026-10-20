import AppKit
import Combine
import FolioCore

extension NoteStore {
    // MARK: Trash

    func restore(_ item: TrashItem) {
        do {
            let url = try trash.restore(item)
            reload()
            if item.isFolder {
                sidebarSelection = .folder(url)
            } else if let ref = notes.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                sidebarSelection = .all
                selectedNoteID = ref.id
            }
        } catch {
            lastError = "Wiederherstellen fehlgeschlagen: \(error.localizedDescription)"
            trashItems = trash.items()
        }
    }

    func deletePermanently(_ item: TrashItem) {
        do { try trash.deletePermanently(item, history: history) } catch {
            lastError = "Endgültiges Löschen fehlgeschlagen: \(error.localizedDescription)"
        }
        trashItems = trash.items()
    }

    func emptyTrash() {
        trash.empty(history: history)
        trashItems = trash.items()
    }

    /// Items older than the setting (30 days by default) leave the trash for good.
    func purgeTrash() {
        let days = ThemeManager.shared.settings.trashRetentionDays
        if days > 0, trash.purge(olderThan: days, history: history) > 0 { trashItems = trash.items() }
    }
}

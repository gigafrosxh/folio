import Foundation
import FolioCore

/// All database connections Folio knows: the ones saved in the settings (every connection created in a
/// database block or SQL code block is remembered) plus those used in the open note.
@MainActor
enum ConnectionLibrary {
    static func remember(_ connection: DatabaseConnection) {
        var list = ThemeManager.shared.settings.savedConnections
        if let i = list.firstIndex(where: { $0.id == connection.id }) { list[i] = connection } else { list.append(connection) }
        ThemeManager.shared.settings.savedConnections = list
    }

    static func all(in doc: NoteDocument?) -> [DatabaseConnection] {
        var seen = Set<UUID>()
        let fromNote = doc?.blocks.compactMap(\.connection) ?? []
        return (fromNote + ThemeManager.shared.settings.savedConnections).filter { seen.insert($0.id).inserted }
    }
}

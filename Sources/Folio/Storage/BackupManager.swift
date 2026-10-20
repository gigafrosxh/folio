import AppKit
import Combine
import FolioCore

/// Automatic library backups: one zip after the set interval (checked at launch and every 30 minutes),
/// each one verified right after it is written, old ones thinned out.
@MainActor
final class BackupManager: ObservableObject {
    static let shared = BackupManager()

    @Published private(set) var backups: [BackupInfo] = []
    @Published private(set) var isRunning = false
    /// Last result shown in the settings ("Gesichert und geprüft: 42 Notizen").
    @Published private(set) var status: String?
    @Published private(set) var lastError: String?
    private var timer: Timer?

    private static let lastKey = "folio.lastBackup"
    var lastBackup: Date? { UserDefaults.standard.object(forKey: Self.lastKey) as? Date }

    /// Where backups go: the setting, else ~/Library/Application Support/Folio/Backups. A test library
    /// (FOLIO_LIBRARY) keeps its backups to itself.
    var directory: URL {
        if let env = ProcessInfo.processInfo.environment["FOLIO_BACKUPS"] { return URL(fileURLWithPath: env) }
        if ProcessInfo.processInfo.environment["FOLIO_LIBRARY"] != nil {
            return LibraryData.folder(NoteStore.shared.rootURL, "backups")
        }
        let custom = ThemeManager.shared.settings.backupFolder
        if !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Folio/Backups", isDirectory: true)
    }

    func start() {
        refresh()
        // A little after launch, so the first backup never slows down opening the app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { MainActor.assumeIsolated { self.runIfDue() } }
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in
            MainActor.assumeIsolated { BackupManager.shared.runIfDue() }
        }
    }

    func refresh() { backups = LibraryBackup.list(in: directory) }

    func runIfDue() {
        let s = ThemeManager.shared.settings
        guard s.backupsEnabled, !isRunning else { return }
        let interval = max(s.backupIntervalHours, 1) * 3600
        if let last = backups.first?.date ?? lastBackup, Date().timeIntervalSince(last) < interval { return }
        backupNow()
    }

    func backupNow() {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        status = "Sichere die Bibliothek …"
        NoteStore.shared.currentDocument?.saveNow()
        let library = NoteStore.shared.rootURL, dir = directory
        Task.detached(priority: .utility) {
            let result: Result<(BackupInfo, BackupCheck), Error> = Result {
                let info = try LibraryBackup.create(library: library, in: dir)
                let check = try LibraryBackup.verify(info.url)
                LibraryBackup.prune(in: dir)
                return (info, check)
            }
            await MainActor.run { BackupManager.shared.finish(result) }
        }
    }

    private func finish(_ result: Result<(BackupInfo, BackupCheck), Error>) {
        isRunning = false
        switch result {
        case .success(let (info, check)):
            UserDefaults.standard.set(info.date, forKey: Self.lastKey)
            if check.isValid {
                status = "Gesichert und geprüft: \(check.notes) Notiz\(check.notes == 1 ? "" : "en"), \(ByteCountFormatter.string(fromByteCount: info.size, countStyle: .file))."
            } else {
                status = nil
                lastError = "Gesichert, aber \(check.damaged.count) Notiz(en) sind schon in der Bibliothek beschädigt: \(check.damaged.prefix(3).joined(separator: ", "))."
            }
        case .failure(let error):
            status = nil
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Checks an existing backup and reports the result.
    func verify(_ backup: BackupInfo) {
        status = "Prüfe die Sicherung …"
        lastError = nil
        let url = backup.url
        Task.detached(priority: .userInitiated) {
            let result = Result { try LibraryBackup.verify(url) }
            await MainActor.run {
                switch result {
                case .success(let check) where check.isValid:
                    BackupManager.shared.status = "Sicherung in Ordnung: \(check.notes) Notizen lassen sich vollständig lesen."
                case .success(let check):
                    BackupManager.shared.status = nil
                    BackupManager.shared.lastError = "In der Sicherung sind \(check.damaged.count) Notiz(en) beschädigt: \(check.damaged.prefix(3).joined(separator: ", "))."
                case .failure(let error):
                    BackupManager.shared.status = nil
                    BackupManager.shared.lastError = error.localizedDescription
                }
            }
        }
    }

    /// Restores a backup as a new folder inside the library; existing notes are never touched.
    func restore(_ backup: BackupInfo) {
        let name = "Wiederhergestellt " + backup.date.formatted(date: .numeric, time: .shortened)
            .replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-")
        do {
            let folder = try LibraryBackup.restore(backup.url, into: NoteStore.shared.rootURL, name: name)
            NoteStore.shared.reload()
            NoteStore.shared.sidebarSelection = .folder(folder)
            status = "Wiederhergestellt in den Ordner „\(folder.lastPathComponent)“."
            lastError = nil
        } catch {
            lastError = "Wiederherstellen fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}

import Foundation

/// A zip archive of the whole library.
public struct BackupInfo: Identifiable, Hashable, Sendable {
    public var url: URL
    public var date: Date
    public var size: Int64
    public var id: URL { url }
}

/// Result of checking a backup: it unpacks, and every note in it decodes with a valid checksum.
public struct BackupCheck: Sendable, Equatable {
    public var notes: Int
    public var damaged: [String]
    public var isValid: Bool { damaged.isEmpty }
}

/// Rotating local backups of the note library as zip files ("Folio-Backup-<stamp>.zip").
///
/// Folio's hidden data folder (versions, trash) is not part of a backup, only the notes and folders.
public enum LibraryBackup {
    public static let prefix = "Folio-Backup-"
    static let manifestName = "Folio-Backup.json"

    public enum BackupError: LocalizedError {
        case tool(String)
        case noLibrary
        public var errorDescription: String? {
            switch self {
            case .tool(let m): return "Die Sicherung ist fehlgeschlagen: \(m)"
            case .noLibrary: return "Der Bibliotheksordner fehlt."
            }
        }
    }

    public static func list(in directory: URL) -> [BackupInfo] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return items.compactMap { url -> BackupInfo? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "zip", name.hasPrefix(prefix), let date = Stamp.date(String(name.dropFirst(prefix.count))) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return BackupInfo(url: url, date: date, size: size)
        }.sorted { $0.date > $1.date }
    }

    /// Zips the library into `directory`. Written under a temporary name first, so an interrupted
    /// backup never looks like a finished one.
    public static func create(library: URL, in directory: URL, date: Date = Date()) throws -> BackupInfo {
        let fm = FileManager.default
        guard fm.fileExists(atPath: library.path) else { throw BackupError.noLibrary }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let final = directory.appendingPathComponent(prefix + Stamp.string(date)).appendingPathExtension("zip")
        let partial = directory.appendingPathComponent(".partial-\(UUID().uuidString).zip")
        let manifest = fm.temporaryDirectory.appendingPathComponent("folio-manifest-\(UUID().uuidString)").appendingPathComponent(manifestName)
        defer {
            try? fm.removeItem(at: partial)
            try? fm.removeItem(at: manifest.deletingLastPathComponent())
        }
        // A small manifest first, so even an empty library gives a valid archive.
        try fm.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let notes = LibraryTrash.noteFiles(in: library).filter { !$0.path.contains("/\(LibraryData.folderName)/") }.count
        let info: [String: Any] = ["library": library.path, "created": ISO8601DateFormatter().string(from: date), "notes": notes]
        try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]).write(to: manifest)
        try run("/usr/bin/zip", ["-q", "-j", partial.path, manifest.path], cwd: nil)
        try run("/usr/bin/zip", ["-r", "-q", "-y", partial.path, ".", "-x", ".folio/*", "*.DS_Store", ".partial-*", "*Folio-Backup-*.zip"], cwd: library, allowNothingToDo: true)
        try fm.moveItem(at: partial, to: final)
        let size = (try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return BackupInfo(url: final, date: date, size: size)
    }

    /// Unpacks the backup into a temporary folder and decodes every note in it.
    public static func verify(_ backup: URL) throws -> BackupCheck {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("folio-backup-check-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        try unpack(backup, to: temp)
        let notes = LibraryTrash.noteFiles(in: temp)
        let base = temp.standardizedFileURL.path
        let damaged = notes.filter { (try? NoteFile.read(from: $0)) == nil }
            .map { String($0.standardizedFileURL.path.dropFirst(base.count + 1)) }
        return BackupCheck(notes: notes.count, damaged: damaged)
    }

    /// Restores a backup into a new folder `name` inside `parent` (never over existing notes).
    public static func restore(_ backup: URL, into parent: URL, name: String) throws -> URL {
        let target = LibraryTrash.uniqueURL(parent.appendingPathComponent(name, isDirectory: true))
        try unpack(backup, to: target)
        try? FileManager.default.removeItem(at: target.appendingPathComponent(manifestName))
        return target
    }

    /// Removes backups the retention policy no longer needs; returns them.
    @discardableResult
    public static func prune(in directory: URL, policy: RetentionPolicy = .backups, now: Date = Date()) -> [URL] {
        let all = list(in: directory)
        let doomed = Set(policy.toDelete(all.map(\.date), now: now))
        return all.filter { doomed.contains($0.date) }.compactMap { b in
            (try? FileManager.default.removeItem(at: b.url)) != nil ? b.url : nil
        }
    }

    static func unpack(_ zip: URL, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path], cwd: nil)
    }

    private static func run(_ exe: String, _ args: [String], cwd: URL?, allowNothingToDo: Bool = false) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { throw BackupError.tool(error.localizedDescription) }
        let message = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // zip exits with 12 when there was nothing to add (an empty library).
        if allowNothingToDo, p.terminationStatus == 12 { return }
        guard p.terminationStatus == 0 else {
            let text = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BackupError.tool(text.isEmpty ? "\((exe as NSString).lastPathComponent) Status \(p.terminationStatus)" : text)
        }
    }
}

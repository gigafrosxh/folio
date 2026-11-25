import Foundation

/// A zip archive of the whole library.
public struct BackupInfo: Identifiable, Hashable, Sendable {
    public var url: URL
    public var date: Date
    public var size: Int64
    public var id: URL { url }
}

/// Result of checking a backup: it unpacks, every note in it decodes with a valid checksum, and every note the
/// manifest lists is there (#324).
public struct BackupCheck: Sendable, Equatable {
    public var notes: Int
    public var damaged: [String]
    /// Notes the manifest lists that are missing from the archive (or, for older backups, how many are missing).
    public var missing: [String] = []
    public var isValid: Bool { damaged.isEmpty && missing.isEmpty }

    /// What is wrong, for the settings: damaged and missing notes, at most three names each.
    public var problems: String {
        var parts: [String] = []
        if !damaged.isEmpty { parts.append("\(damaged.count) Notiz(en) beschädigt: \(damaged.prefix(3).joined(separator: ", "))") }
        if !missing.isEmpty { parts.append("es fehlen \(missing.prefix(3).joined(separator: ", "))\(missing.count > 3 ? " …" : "")") }
        return parts.joined(separator: "; ")
    }
}

/// Rotating local backups of the note library as zip files ("Folio-Backup-<stamp>.zip").
///
/// Folio's hidden data folder (versions, trash) is not part of a backup, only the notes and folders.
public enum LibraryBackup {
    public static let prefix = "Folio-Backup-"
    /// Manifest of backups before 1.11.12, in the archive's root (where a library file of that name could replace it).
    static let manifestName = "Folio-Backup.json"
    /// Since 1.11.12 the manifest has a folder of its own that the library never backs up (#367).
    static let manifestFolder = ".folio-backup"
    static var manifestPath: String { manifestFolder + "/manifest.json" }

    public enum BackupError: LocalizedError {
        case tool(String)
        case noLibrary
        /// The archive is not a plausible Folio backup: unsafe paths, links out of it, too many or too large files (#282).
        case unsafeArchive(String)
        public var errorDescription: String? {
            switch self {
            case .tool(let m): return "Die Sicherung ist fehlgeschlagen: \(m)"
            case .noLibrary: return "Der Bibliotheksordner fehlt."
            case .unsafeArchive(let m): return "Diese Sicherung wird nicht entpackt: \(m)"
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

    #if os(macOS)
        /// Zips the library into `directory`. Written under a temporary name first, so an interrupted
        /// backup never looks like a finished one.
        public static func create(library: URL, in directory: URL, date: Date = Date()) throws -> BackupInfo {
            let fm = FileManager.default
            guard fm.fileExists(atPath: library.path) else { throw BackupError.noLibrary }
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let final = directory.appendingPathComponent(prefix + Stamp.string(date)).appendingPathExtension("zip")
            let partial = directory.appendingPathComponent(".partial-\(UUID().uuidString).zip")
            let manifestRoot = fm.temporaryDirectory.appendingPathComponent("folio-manifest-\(UUID().uuidString)")
            let manifest = manifestRoot.appendingPathComponent(manifestPath)
            defer {
                try? fm.removeItem(at: partial)
                try? fm.removeItem(at: manifestRoot)
            }
            // A small manifest first, so even an empty library gives a valid archive.
            try fm.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = library.standardizedFileURL.path
            let files = LibraryTrash.noteFiles(in: library).filter { !$0.path.contains("/\(LibraryData.folderName)/") }
                .map { String($0.standardizedFileURL.path.dropFirst(base.count + 1)) }.sorted()
            // The note list lets the check find notes missing from the archive, not only damaged ones (#324).
            let info: [String: Any] = [
                "library": library.path, "created": ISO8601DateFormatter().string(from: date), "notes": files.count, "files": files
            ]
            try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]).write(to: manifest)
            try run("/usr/bin/zip", ["-q", partial.path, manifestPath], cwd: manifestRoot)
            try run(
                "/usr/bin/zip", ["-r", "-q", "-y", partial.path, ".", "-x", ".folio/*", "\(manifestFolder)/*", "*.DS_Store", ".partial-*", "*Folio-Backup-*.zip"], cwd: library,
                allowNothingToDo: true)
            // Folio's own folder stays out (history, trash, caches), except the library's order, favorites and smart views (#176).
            if fm.fileExists(atPath: LibraryOrganization.file(in: library).path) {
                try run("/usr/bin/zip", ["-q", partial.path, "\(LibraryData.folderName)/organization.json"], cwd: library, allowNothingToDo: true)
            }
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
            let paths = notes.map { String($0.standardizedFileURL.path.dropFirst(base.count + 1)) }
            let damaged = zip(notes, paths).filter { (try? NoteFile.read(from: $0.0)) == nil }.map(\.1)
            return BackupCheck(notes: notes.count, damaged: damaged, missing: missing(manifest: manifestURL(in: temp), found: paths))
        }

        /// The manifest of an unpacked backup: its own folder, or the root for backups before 1.11.12 (#367).
        static func manifestURL(in folder: URL) -> URL {
            let current = folder.appendingPathComponent(manifestPath)
            return FileManager.default.fileExists(atPath: current.path) ? current : folder.appendingPathComponent(manifestName)
        }

        /// What the manifest lists but the archive lacks. Older backups only stored the number of notes; a missing
        /// or unreadable manifest fails the check, since then nothing says what should be there (#324).
        static func missing(manifest: URL, found: [String]) -> [String] {
            guard let data = try? Data(contentsOf: manifest),
                let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [manifestName] }
            // The set is built once: a large library is checked in linear time (#370).
            if let files = info["files"] as? [String] {
                let present = Set(found)
                return files.filter { !present.contains($0) }
            }
            if let count = info["notes"] as? Int {
                return count > found.count ? ["\(count - found.count) von \(count) Notizen"] : []
            }
            // Neither a note list nor a count: nothing says what should be there (#370).
            return [manifestName]
        }

        /// Restores a backup into a new folder `name` inside `parent` (never over existing notes). Unpacked into a hidden
        /// staging folder next to it first and moved into place only when complete, so a failure leaves nothing
        /// half-restored behind (#325).
        public static func restore(_ backup: URL, into parent: URL, name: String) throws -> URL {
            let fm = FileManager.default
            let staging = parent.appendingPathComponent(".folio-restore-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: staging) }
            try unpack(backup, to: staging)
            // Only the manifest goes; a library file that happens to be called like the old manifest stays (#367).
            if fm.fileExists(atPath: staging.appendingPathComponent(manifestPath).path) {
                try? fm.removeItem(at: staging.appendingPathComponent(manifestFolder))
            } else {
                try? fm.removeItem(at: staging.appendingPathComponent(manifestName))
            }
            let target = LibraryTrash.uniqueURL(parent.appendingPathComponent(name, isDirectory: true))
            try fm.moveItem(at: staging, to: target)
            return target
        }

    #endif

    /// Removes backups the retention policy no longer needs; returns them.
    @discardableResult
    public static func prune(in directory: URL, policy: RetentionPolicy = .backups, now: Date = Date()) -> [URL] {
        let all = list(in: directory)
        let doomed = Set(policy.toDelete(all.map(\.date), now: now))
        return all.filter { doomed.contains($0.date) }.compactMap { b in
            (try? FileManager.default.removeItem(at: b.url)) != nil ? b.url : nil
        }
    }

    #if os(macOS)
        /// Most files and bytes a backup may unpack to (#282); the free space of the target counts too.
        static let maxEntries = 500_000
        static let maxUnpacked: UInt64 = 256 << 30

        /// Unpacks only after checking the archive's table of contents (no absolute paths, no `..`, limited number
        /// and size of files) and afterwards that no symbolic link leads out of the folder (#282).
        static func unpack(_ zip: URL, to folder: URL) throws {
            let entries = try contents(of: zip)
            let free = freeSpace(at: folder.deletingLastPathComponent())
            try check(entries, freeSpace: free)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path], cwd: nil)
            // Links out of the backup (e.g. a folder link the library had) are dropped; the library never follows
            // them either (#56).
            for link in linksOutside(folder) { try? FileManager.default.removeItem(at: link) }
        }

        /// Free space where the backup is unpacked. Some environments report 0 for "important usage"; the larger of the
        /// two values counts, so a tiny backup is never refused for lack of space (#370).
        static func freeSpace(at folder: URL) -> UInt64 {
            let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            let important = values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) } ?? 0
            let regular = values?.volumeAvailableCapacity.map { UInt64(max($0, 0)) } ?? 0
            let best = max(important, regular)
            return best > 0 ? best : maxUnpacked
        }

        struct Entry: Equatable {
            var size: UInt64
            var path: String
        }

        /// The archive's table of contents as `unzip -l` lists it.
        static func contents(of zip: URL) throws -> [Entry] {
            let listing = try output("/usr/bin/unzip", ["-l", zip.path])
            let lines = listing.components(separatedBy: "\n")
            guard let start = lines.firstIndex(where: { $0.hasPrefix("---") }) else { throw BackupError.unsafeArchive("kein lesbares ZIP-Archiv.") }
            let body = lines[(start + 1)...].prefix { !$0.hasPrefix("---") }
            return try body.map { line in
                let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard parts.count == 4, let size = UInt64(parts[0]) else { throw BackupError.unsafeArchive("unlesbares Inhaltsverzeichnis.") }
                return Entry(size: size, path: String(parts[3].drop { $0 == " " }))
            }
        }

        static func check(_ entries: [Entry], freeSpace: UInt64) throws {
            guard entries.count <= maxEntries else { throw BackupError.unsafeArchive("zu viele Dateien (\(entries.count)).") }
            if let bad = entries.first(where: { $0.path.hasPrefix("/") || $0.path.split(separator: "/").contains("..") }) {
                throw BackupError.unsafeArchive("„\(bad.path)“ liegt außerhalb des Sicherungsordners.")
            }
            // Summed with the limit checked at every step: an overflow or a sum past the limit stops at once (#374).
            let limit = min(maxUnpacked, freeSpace)
            var total: UInt64 = 0
            for entry in entries {
                let (sum, overflow) = total.addingReportingOverflow(entry.size)
                guard !overflow, sum <= limit else {
                    let shown =
                        overflow
                        ? "mehr als \(ByteCountFormatter.string(fromByteCount: Int64(clamping: limit), countStyle: .file))"
                        : ByteCountFormatter.string(fromByteCount: Int64(clamping: sum), countStyle: .file)
                    throw BackupError.unsafeArchive("sie würde \(shown) belegen.")
                }
                total = sum
            }
        }

        /// Symbolic links in `folder` whose target lies outside it.
        static func linksOutside(_ folder: URL) -> [URL] {
            let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
            let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])
            var links: [URL] = []
            while let url = e?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { continue }
                if !url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root + "/") { links.append(url) }
            }
            return links
        }

        private static func output(_ exe: String, _ args: [String]) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { throw BackupError.tool(error.localizedDescription) }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw BackupError.unsafeArchive("kein lesbares ZIP-Archiv.") }
            return String(decoding: data, as: UTF8.self)
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
    #endif
}

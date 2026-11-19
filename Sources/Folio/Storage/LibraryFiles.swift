import Foundation
import FolioCore

/// The library on disk, without UI state (#216): reading it, repairing duplicate note ids, creating, renaming and
/// trashing folders, finding free file names. Every operation returns a typed result; `NoteStore` decides what the
/// interface shows. Safe to use off the main thread.
struct LibraryFiles: Sendable {
    let root: URL

    enum Failure: LocalizedError, Equatable {
        case folderNotCreated(String)
        case folderNotRenamed(String)
        case folderNotTrashed(String)
        case duplicatesNotRenewed([String])

        var errorDescription: String? {
            switch self {
            case .folderNotCreated(let why): return "Ordner konnte nicht angelegt werden: \(why)"
            case .folderNotRenamed(let why): return "Umbenennen fehlgeschlagen: \(why)"
            case .folderNotTrashed(let why): return "Ordner konnte nicht gelöscht werden: \(why)"
            case .duplicatesNotRenewed(let names):
                return "Diese Kopien haben dieselbe Kennung wie eine andere Notiz und konnten nicht angepasst werden: \(names.joined(separator: ", "))"
            }
        }
    }

    static let defaultFolderName = "Notizen"

    /// Creates the library folder, and a first folder in an empty library.
    func prepare() {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        if (try? fm.contentsOfDirectory(atPath: root.path))?.filter({ !$0.hasPrefix(".") }).isEmpty ?? true {
            try? fm.createDirectory(at: root.appendingPathComponent(Self.defaultFolderName, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    // MARK: Reading

    func read(scanner: LibraryScanner) -> NoteStore.LibrarySnapshot {
        let result = scanner.scan(root)
        let damaged = result.unreadable.map { DamagedNote(url: $0, report: FolioDiagnostics.diagnose(at: $0)) }
        let dir = LibraryData.folder(root, "templates")
        let templates = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == FolioArchive.fileExtension }
            .compactMap { url in (try? NoteFile.readMetadata(at: url)).map { NoteRef(meta: $0, url: url) } }
        return NoteStore.LibrarySnapshot(
            root: root, scan: result, refs: result.notes.map { NoteRef(meta: $0.meta, url: $0.url) }, damaged: damaged,
            trash: LibraryTrash(library: root).items(), templates: templates)
    }

    /// Copies of a note file with the same id get a new identity, so each shows up as its own note (#166). The file
    /// known under the id before keeps it. Copies that cannot be rewritten stay out of the list and are reported.
    func renewingDuplicateIDs(_ found: [NoteRef], known: [UUID: URL]) -> (refs: [NoteRef], failure: Failure?) {
        guard Set(found.map(\.id)).count != found.count else { return (found, nil) }
        let resolution = NoteIdentity.resolve(found.map { ($0.url, $0.id) }, known: known)
        guard !resolution.renew.isEmpty else { return (found, nil) }
        let renew = Set(resolution.renew)
        var refs = found.filter { !renew.contains($0.url) }
        var failed: [String] = []
        for url in resolution.renew {
            do {
                let file = NoteIdentity.renewed(try NoteFile.read(from: url))
                try file.write(to: url)
                refs.append(NoteRef(meta: file.meta, url: url))
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        return (refs, failed.isEmpty ? nil : .duplicatesNotRenewed(failed))
    }

    // MARK: Folders

    func createFolder(named name: String, in parent: URL? = nil) -> Result<URL, Failure> {
        let dir = (parent ?? root).appendingPathComponent(Self.sanitize(name), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            return .success(dir)
        } catch {
            return .failure(.folderNotCreated(error.localizedDescription))
        }
    }

    func renameFolder(_ url: URL, to name: String) -> Result<URL, Failure> {
        let target = url.deletingLastPathComponent().appendingPathComponent(Self.sanitize(name), isDirectory: true)
        guard target != url else { return .success(url) }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return .success(target)
        } catch {
            return .failure(.folderNotRenamed(error.localizedDescription))
        }
    }

    func trashFolder(_ url: URL) -> Result<TrashItem, Failure> {
        do {
            return .success(try LibraryTrash(library: root).moveToTrash(url))
        } catch {
            return .failure(.folderNotTrashed(error.localizedDescription))
        }
    }

    // MARK: Names

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0").union(.newlines).union(.controlCharacters)
        var s = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "Ohne Titel" }
        return String(s.prefix(80))
    }

    /// `<dir>/<base>.folio`, or `<base> 2.folio`, `<base> 3.folio` … when taken.
    static func uniqueURL(in dir: URL, base: String) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(base).appendingPathExtension(FolioArchive.fileExtension)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(FolioArchive.fileExtension)
            n += 1
        }
        return url
    }
}

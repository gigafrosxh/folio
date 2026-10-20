import AppKit
import Combine
import FolioCore

extension NoteStore {
    // MARK: Damaged notes

    /// Saves what could be rescued as a new note and moves the damaged file aside (never deletes it).
    func salvage(_ damaged: DamagedNote) {
        guard let file = damaged.report.salvagedFile() else { return }
        let url = uniqueURL(in: damaged.url.deletingLastPathComponent(), base: Self.sanitize(file.meta.title))
        do {
            try file.write(to: url)
            try quarantine(damaged.url)
        } catch {
            lastError = "Retten fehlgeschlagen: \(error.localizedDescription)"
            return
        }
        if let id = damaged.report.meta?.id { failures[id] = nil }
        failures = failures.filter { $0.value.url != damaged.url }
        reload()
        sidebarSelection = .all
        selectedNoteID = file.meta.id
    }

    /// Restores the newest intact version of a damaged note in place (the damaged file is kept aside).
    func restoreLatestVersion(_ damaged: DamagedNote) {
        guard let id = damaged.report.meta?.id, let version = history.versions(of: id).first(where: { (try? history.read($0)) != nil }),
              var file = try? history.read(version) else { return }
        do {
            try quarantine(damaged.url)
            file.meta.modified = Date()
            try file.write(to: damaged.url)
        } catch {
            lastError = "Wiederherstellen fehlgeschlagen: \(error.localizedDescription)"
            return
        }
        failures[id] = nil
        reload()
        ensureLoaded(id)
        selectedNoteID = id
    }

    /// The newest readable version of a damaged note, if the history has one.
    func latestIntactVersion(of damaged: DamagedNote) -> NoteVersion? {
        guard let id = damaged.report.meta?.id else { return nil }
        return history.versions(of: id).first { (try? history.read($0)) != nil }
    }

    /// Damaged originals go to `.folio/damaged/`, so they can still be examined or sent in.
    func quarantine(_ url: URL) throws {
        let dir = LibraryData.folder(rootURL, "damaged")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent(Stamp.string(Date()) + "-" + url.lastPathComponent))
    }
}

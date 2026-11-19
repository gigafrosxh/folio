import AppKit
import UniformTypeIdentifiers
import FolioCore

/// „Obsidian-Vault importieren …“ (#71): every Markdown note of a vault becomes a Folio note in a new folder named like
/// the vault, with the same subfolders. Links stay links, embedded files become blocks, front matter becomes tags and
/// properties. The vault itself is only read; nothing in the library is overwritten.
@MainActor
enum ObsidianImporter {
    struct Report: Equatable {
        var notes = 0
        var missing: [String] = []
        var failures: [String] = []
        var folder: URL?
    }

    static func importWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Obsidian-Vault (Ordner) wählen – er wird nur gelesen"
        panel.prompt = "Importieren"
        guard panel.runModal() == .OK, let vault = panel.url else { return }
        Task { show(await importVault(vault, into: NoteStore.shared.rootURL), vault: vault) }
    }

    private static func show(_ report: Report, vault: URL) {
        let alert = NSAlert()
        alert.messageText = "\(report.notes) Notiz\(report.notes == 1 ? "" : "en") aus „\(vault.lastPathComponent)“ importiert"
        var lines: [String] = []
        if let folder = report.folder { lines.append("Ordner: \(folder.lastPathComponent)") }
        if !report.missing.isEmpty { lines.append("Nicht gefundene Anhänge: " + report.missing.prefix(10).joined(separator: ", ") + (report.missing.count > 10 ? " …" : "")) }
        if !report.failures.isEmpty { lines.append("Nicht importiert:\n" + report.failures.prefix(10).joined(separator: "\n")) }
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.runModal()
    }

    /// Imports into a new folder below `library`; returns what happened.
    /// Imports into a new folder below `library`. Scanning and reading run off the main thread, and the main thread gets a
    /// break after every note, so a large vault does not freeze Folio (#350).
    static func importVault(_ vault: URL, into library: URL) async -> Report {
        var report = Report()
        let (notes, files) = await Task.detached(priority: .userInitiated) { ObsidianImport.scan(vault) }.value
        guard !notes.isEmpty else {
            report.failures.append("Im Ordner liegen keine Markdown-Notizen.")
            return report
        }
        let folder = uniqueFolder(library.appendingPathComponent(NoteStore.sanitize(vault.lastPathComponent), isDirectory: true))
        report.folder = folder
        for rel in notes {
            do {
                let text = try await Task.detached(priority: .userInitiated) { try readText(vault.appendingPathComponent(rel)) }.value
                try importNote(rel, text: text, vault: vault, files: files, into: folder, report: &report)
            } catch {
                report.failures.append("\(rel): \(error.localizedDescription)")
            }
            await Task.yield()
        }
        NoteStore.shared.reload()
        return report
    }

    nonisolated private static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    private static func importNote(_ rel: String, text: String, vault: URL, files: [String: String], into folder: URL, report: inout Report) throws {
        let source = vault.appendingPathComponent(rel)
        let title = (rel as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "", options: [.caseInsensitive, .anchored, .backwards])
        let prepared = ObsidianImport.prepare(text, title: title, files: files, noteFolder: (rel as NSString).deletingLastPathComponent)
        report.missing += prepared.missing
        var file = MarkdownTransfer.note(fromMarkdown: prepared.markdown, title: title, baseURL: vault)
        if !prepared.properties.isEmpty {
            file.meta.properties = prepared.properties.map { NoteProperty(name: $0.name, kind: .text, value: $0.value) }
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        if let created = attrs?[.creationDate] as? Date { file.meta.created = created }
        if let modified = attrs?[.modificationDate] as? Date { file.meta.modified = modified }
        let dir = folder.appendingPathComponent((rel as NSString).deletingLastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = MarkdownTransfer.uniqueURL(dir.appendingPathComponent(NoteStore.sanitize(title)).appendingPathExtension(FolioArchive.fileExtension))
        try file.write(to: target)
        report.notes += 1
    }

    private static func uniqueFolder(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        var n = 2
        while FileManager.default.fileExists(atPath: url.path + " \(n)") { n += 1 }
        return URL(fileURLWithPath: url.path + " \(n)", isDirectory: true)
    }
}

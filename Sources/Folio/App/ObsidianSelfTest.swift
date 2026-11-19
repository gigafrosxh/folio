import AppKit
import FolioCore

/// Obsidian import (#71), part of FOLIO_ORG_TEST: a small vault with folders, links, front matter and attachments.
@MainActor
enum ObsidianSelfTest {
    private static func check(_ ok: Bool, _ label: String) {
        print("ORG", ok ? "ok" : "FAIL", label)
        fflush(stdout)
    }

    static func run(store: NoteStore) {
        let fm = FileManager.default
        let vault = fm.temporaryDirectory.appendingPathComponent("Mein Vault \(UUID().uuidString.prefix(6))", isDirectory: true)
        try? fm.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: vault.appendingPathComponent("Projekte/Anhänge"), withIntermediateDirectories: true)
        try? "{}".write(to: vault.appendingPathComponent(".obsidian/app.json"), atomically: true, encoding: .utf8)
        try? "---\ntags: [obsidian]\nstatus: offen\n---\nVerweis auf [[Plan|den Plan]].\n![[Logo.png]]\n![[weg.pdf]]"
            .write(to: vault.appendingPathComponent("Start.md"), atomically: true, encoding: .utf8)
        try? "# Plan\nInhalt des Plans" .write(to: vault.appendingPathComponent("Projekte/Plan.md"), atomically: true, encoding: .utf8)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        try? png.write(to: vault.appendingPathComponent("Projekte/Anhänge/Logo.png"))
        let before = store.notes.count
        let report = ObsidianImporter.importVault(vault, into: store.rootURL)
        check(report.notes == 2 && store.notes.count == before + 2, "Obsidian: zwei Notizen importiert")
        check(report.missing == ["weg.pdf"], "Obsidian: fehlender Anhang gemeldet")
        guard let start = store.notes.first(where: { $0.meta.title == "Start" }), let file = try? NoteFile.read(from: start.url) else {
            return check(false, "Obsidian: Notiz „Start“ mit Dateinamen als Titel")
        }
        check(start.url.path.contains("/Mein Vault"), "Obsidian: in eigenem Ordner wie der Vault")
        check(store.notes.contains { $0.meta.title == "Plan" && $0.url.path.contains("/Projekte/") }, "Obsidian: Unterordner bleiben")
        check(file.meta.tags.contains("obsidian"), "Obsidian: Tags aus dem Front Matter")
        check(file.meta.properties?.contains { $0.name == "status" && $0.value == "offen" } == true, "Obsidian: Eigenschaften aus dem Front Matter")
        check(file.body.blocks.contains { $0.kind == .image } && file.attachments.contains { $0.header.filename == "Logo.png" }, "Obsidian: eingebettetes Bild aus anderem Ordner")
        check(store.linkIndex.resolve("Plan") != nil && file.meta.wikiLinks?.contains("Plan") == true, "Obsidian: [[Link]] zeigt auf die importierte Notiz")
        check(fm.fileExists(atPath: vault.appendingPathComponent("Start.md").path), "Obsidian: Vault bleibt unverändert")
        let again = ObsidianImporter.importVault(vault, into: store.rootURL)
        check(again.folder?.lastPathComponent.hasSuffix(" 2") == true, "Obsidian: zweiter Import in neuen Ordner, nichts überschrieben")
    }
}

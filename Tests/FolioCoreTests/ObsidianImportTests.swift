import XCTest
@testable import FolioCore

final class ObsidianImportTests: XCTestCase {
    func testFrontMatterTagsAndProperties() {
        let md = "---\ntags: [projekt, \"idee\"]\nstatus: offen\naliases:\n  - X\nquellen:\n  - a\n  - b\n---\nText"
        let p = ObsidianImport.prepare(md, title: "Notiz", files: [:])
        XCTAssertEqual(p.tags, ["projekt", "idee"])
        XCTAssertEqual(p.properties.map { $0.name + "=" + $0.value }, ["status=offen", "quellen=a, b"])
        XCTAssertTrue(p.markdown.hasPrefix("# Notiz\n\nText"))
        XCTAssertTrue(p.markdown.hasSuffix("#projekt #idee"))
    }

    func testTagListStyle() {
        let p = ObsidianImport.prepare("---\ntags:\n  - a\n  - b\n---\n# Titel\nx", title: "Titel", files: [:])
        XCTAssertEqual(p.tags, ["a", "b"])
        XCTAssertTrue(p.markdown.hasPrefix("# Titel\nx"), "title line already there")
    }

    func testEmbedsAndLinks() {
        let files = ["bild 1.png": "Anhänge/bild 1.png", "plan.pdf": "plan.pdf"]
        let md = "# N\nSiehe [[Ordner/Andere#Abschnitt|hier]] und [[Dritte]].\n![[bild 1.png|300]]\n![[plan.pdf]]\n![[Andere Notiz]]\n![[fehlt.png]]"
        let p = ObsidianImport.prepare(md, title: "N", files: files)
        XCTAssertTrue(p.markdown.contains("[[Andere|hier]]"))
        XCTAssertTrue(p.markdown.contains("[[Dritte]]"))
        XCTAssertTrue(p.markdown.contains("![bild 1.png](Anh%C3%A4nge/bild%201.png)"))
        XCTAssertTrue(p.markdown.contains("![plan.pdf](plan.pdf)"))
        XCTAssertTrue(p.markdown.contains("[[Andere Notiz]]"))
        XCTAssertEqual(p.missing, ["fehlt.png"])
    }

    func testScanSkipsObsidianFolders() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try fm.createDirectory(at: vault.appendingPathComponent("Projekte/Bilder"), withIntermediateDirectories: true)
        try "x".write(to: vault.appendingPathComponent(".obsidian/app.json"), atomically: true, encoding: .utf8)
        try "a".write(to: vault.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        try "b".write(to: vault.appendingPathComponent("Projekte/B.md"), atomically: true, encoding: .utf8)
        try Data([1]).write(to: vault.appendingPathComponent("Projekte/Bilder/x.png"))
        let s = ObsidianImport.scan(vault)
        XCTAssertEqual(s.notes, ["A.md", "Projekte/B.md"])
        XCTAssertEqual(s.files["x.png"], "Projekte/Bilder/x.png")
        XCTAssertNil(s.files["app.json"])
    }
}

import XCTest
@testable import FolioCore

/// Graph layouts and diagnosis texts compared with a stored result (#150, #153). FOLIO_WRITE_GOLDEN=1 rewrites it.
final class GraphAndScanGoldenTests: XCTestCase {
    private func ids(_ n: Int) -> [UUID] {
        (0..<n).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    }

    private func compare(_ text: String, with name: String) throws {
        if ProcessInfo.processInfo.environment["FOLIO_WRITE_GOLDEN"] != nil { try text.write(to: fixture(name), atomically: true, encoding: .utf8) }
        XCTAssertEqual(text, try String(contentsOf: fixture(name), encoding: .utf8))
    }

    /// Several shapes: empty, single, a cycle, a star, a chain with self-links and unknown ids, and a bigger graph.
    private var graphs: [(String, [UUID], [(UUID, UUID)])] {
        let n = ids(60)
        let cycle = (0..<5).map { (n[$0], n[($0 + 1) % 5]) }
        let star = (1..<8).map { (n[0], n[$0]) }
        let chain = (0..<5).map { (n[$0], n[$0 + 1]) } + [(n[2], n[2]), (n[3], UUID())]
        var big: [(UUID, UUID)] = []
        for i in 0..<60 { big.append((n[i], n[(i * 7 + 3) % 60])); if i % 4 == 0 { big.append((n[i], n[(i + 11) % 60])) } }
        return [("leer", [], []), ("eins", [n[0]], []), ("kreis", Array(n[0..<5]), cycle), ("stern", Array(n[0..<8]), star),
                ("kette", Array(n[0..<6]), chain), ("gross", n, big)]
    }

    private func line(_ id: UUID, _ values: [Double]) -> String {
        "\(id.uuidString.suffix(4)) " + values.map { String(format: "%.9f", $0) }.joined(separator: " ")
    }

    func testLayoutsMatchStoredResult() throws {
        var out = ""
        for (name, nodes, edges) in graphs {
            let flat = GraphLayout.compute(nodes: nodes, edges: edges, iterations: 120)
            let deep = GraphLayout.compute3D(nodes: nodes, edges: edges, iterations: 120)
            out += "== \(name)\n" + nodes.map { line($0, [flat[$0]!.x, flat[$0]!.y]) }.joined(separator: "\n") + "\n"
            out += "-- 3d\n" + nodes.map { line($0, [deep[$0]!.x, deep[$0]!.y, deep[$0]!.z]) }.joined(separator: "\n") + "\n"
        }
        let n = ids(3)
        let resumed = GraphLayout.compute(nodes: n, edges: [(n[0], n[1])], iterations: 20, previous: [n[0]: CGPoint(x: 5, y: 5)])
        out += "== fortgesetzt\n" + n.map { line($0, [resumed[$0]!.x, resumed[$0]!.y]) }.joined(separator: "\n") + "\n"
        try compare(out, with: "graph-layout.txt")
    }

    func testLayoutIsDeterministic() {
        let (_, nodes, edges) = graphs[5]
        XCTAssertEqual(GraphLayout.compute(nodes: nodes, edges: edges, iterations: 50), GraphLayout.compute(nodes: nodes, edges: edges, iterations: 50))
    }

    func testFolderGraph() {
        let n = ids(4)
        let (folders, edges) = FolderGraph.augment(notes: [(n[0], "A/B/C"), (n[1], "A/B"), (n[2], ""), (n[3], "D")])
        XCTAssertEqual(Set(folders.values), ["A/B/C", "A/B", "A", "D"])
        let named = edges.map { [$0.0, $0.1].map { folders[$0] ?? $0.uuidString.suffix(4).description }.joined(separator: "→") }
        XCTAssertEqual(named, ["0000→A/B/C", "A/B/C→A/B", "A/B→A", "0001→A/B", "0003→D"])
    }

    /// Every way a note file can break, and the words the diagnosis uses for it.
    func testDiagnosisTextsMatchStoredResult() throws {
        var b = BlockRecord(kind: .image)
        b.attachmentID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        var meta = NoteMetadata(title: "Ä 😀")
        meta.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        meta.created = Date(timeIntervalSince1970: 0)
        meta.modified = Date(timeIntervalSince1970: 0)
        var withAttachment = NoteFile(meta: meta, body: NoteBody(blocks: [b]))
        withAttachment.attachments = [FolioArchive.Attachment(filename: "a.png", typeIdentifier: "public.png", data: Data(repeating: 7, count: 300))]
        let good = try withAttachment.encoded()
        let missing = try NoteFile(meta: meta, body: NoteBody(blocks: [b])).encoded()
        var flipped = good
        flipped[flipped.count / 2] ^= 0xFF
        var newer = good
        newer[4] = 0xFF
        let cases: [(String, Data)] = [
            ("gut", good), ("leer", Data()), ("fremd", Data("HALLO".utf8)), ("nur kennung", good.prefix(4)),
            ("neuer", newer), ("abgeschnitten kopf", good.prefix(12)), ("abgeschnitten mitte", good.prefix(good.count / 2)),
            ("abgeschnitten ende", good.prefix(good.count - 20)), ("verfälscht", flipped), ("fehlender anhang", missing),
        ]
        let text = cases.map { name, data in
            let r = FolioDiagnostics.diagnose(data)
            return "== \(name): blocks \(r.blocks.count) attachments \(r.attachments.count) lost \(r.lostBlocks)/\(r.lostAttachments)\n"
                + r.problems.map { "\($0.severity) \($0.message)" }.joined(separator: "\n")
        }.joined(separator: "\n") + "\n"
        try compare(text, with: "diagnosis.txt")
    }

    func testUnreadableFileIsReported() {
        let r = FolioDiagnostics.diagnose(at: URL(fileURLWithPath: "/nicht/vorhanden.folio"))
        XCTAssertEqual(r.problems.first?.severity, .error)
        XCTAssertTrue(r.problems.first?.message.contains("nicht gelesen") == true)
    }

    func testTextDiff() {
        let lines = TextDiff.lines("a\nb\nc", "a\nx\nc\nd")
        XCTAssertEqual(lines.map { "\($0.kind) \($0.text)" }, ["same a", "removed b", "added x", "same c", "added d"])
        XCTAssertEqual(TextDiff.lines("", "").map(\.text), [""])
        XCTAssertEqual(TextDiff.lines("a", "").map { "\($0.kind)" }, ["removed", "added"])
    }
}

/// Scanning a library with links, loops, broken notes and folders without access (#153).
final class LibraryScanEdgeCaseTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("folio-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("A/B"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("Gesperrt").path)
        try? FileManager.default.removeItem(at: root)
    }

    private func note(_ path: String, title: String) throws {
        try NoteFile(meta: NoteMetadata(title: title), body: NoteBody()).write(to: root.appendingPathComponent(path))
    }

    func testLinksLoopsAndBrokenFiles() throws {
        let fm = FileManager.default
        try note("A/Eins.folio", title: "Eins")
        try note("A/B/Zwei.folio", title: "Zwei")
        try Data("kaputt".utf8).write(to: root.appendingPathComponent("A/Kaputt.folio"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("A/B/Zurück"), withDestinationURL: root.appendingPathComponent("A"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Draußen"), withDestinationURL: fm.temporaryDirectory)
        try fm.createSymbolicLink(at: root.appendingPathComponent("Weg"), withDestinationURL: root.appendingPathComponent("gibt-es-nicht"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Verweis.folio"), withDestinationURL: root.appendingPathComponent("A/Eins.folio"))
        let r = LibraryScanner().scan(root)
        XCTAssertEqual(r.notes.map(\.meta.title).sorted(), ["Eins", "Zwei"], "die verlinkte Notiz zählt nur einmal")
        XCTAssertEqual(r.unreadable.map(\.lastPathComponent), ["Kaputt.folio"])
        XCTAssertEqual(r.skippedLinks.map { "\($0.url.lastPathComponent): \($0.reason)" }.sorted(),
                       ["Draußen: zeigt aus der Bibliothek heraus", "Weg: Ziel fehlt", "Zurück: Schleife (Ordner ist schon enthalten)"])
        XCTAssertEqual(r.folders.map(\.name), ["A"])
        XCTAssertEqual(r.folders.first?.children.map(\.name), ["B"])
        XCTAssertEqual(String(decoding: try Data(contentsOf: root.appendingPathComponent("A/Kaputt.folio")), as: UTF8.self), "kaputt", "nichts wird verändert")
    }

    func testFolderWithoutAccessIsSkippedQuietly() throws {
        let locked = root.appendingPathComponent("Gesperrt")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try note("Gesperrt/Geheim.folio", title: "Geheim")
        try note("Offen.folio", title: "Offen")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let r = LibraryScanner().scan(root)
        XCTAssertEqual(r.notes.map(\.meta.title), ["Offen"])
        XCTAssertEqual(r.folders.map(\.name).sorted(), ["A", "Gesperrt"])
    }

    func testRescanUsesCache() throws {
        try note("A/Eins.folio", title: "Eins")
        let scanner = LibraryScanner()
        XCTAssertEqual(scanner.scan(root).cacheHits, 0)
        XCTAssertEqual(scanner.scan(root).cacheHits, 1)
    }
}

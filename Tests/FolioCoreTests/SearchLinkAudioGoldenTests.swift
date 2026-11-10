import AVFoundation
import XCTest
@testable import FolioCore

/// Search filters, folio:// links and waveforms compared with a stored result (#154, #155). FOLIO_WRITE_GOLDEN=1 rewrites it.
final class SearchLinkAudioGoldenTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    }

    private func compare(_ text: String, with name: String) throws {
        if ProcessInfo.processInfo.environment["FOLIO_WRITE_GOLDEN"] != nil { try text.write(to: fixture(name), atomically: true, encoding: .utf8) }
        XCTAssertEqual(text, try String(contentsOf: fixture(name), encoding: .utf8))
    }

    private let queries = [
        "", "apfel", "tag:Rezept", "#rezept #2026", "#", "tag:", "ordner:Projekte/Alpha", "typ:code", "typ:Bild", "typ:unbekannt",
        "seit:heute", "seit:7", "seit:monat", "seit:jahr", "seit:gestern", "status:offen", "status:*", "https://e.example", "folio:x",
        "Größe:groß", "a:b:c", ":x", "x:", "äpfel  birne", "tag:#rezept ordner:Küche seit:30 typ:code text",
    ]

    private func describe(_ f: SearchFilter) -> String {
        "text=\(f.text) tags=\(f.tags.sorted()) folder=\(f.folder ?? "-") period=\(f.period) types=\(f.types.sorted()) props=\(f.properties.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })"
    }

    private var notes: [(NoteMetadata, String, [String])] {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func note(_ title: String, text: String, tags: [String], daysOld: Double, kinds: [String], props: [NoteProperty] = []) -> NoteMetadata {
            var m = NoteMetadata(title: title, tags: tags)
            m.searchText = text
            m.modified = now.addingTimeInterval(-daysOld * 86_400)
            m.kinds = kinds
            m.properties = props
            return m
        }
        return [
            (note("Apfelkuchen", text: "Äpfel und Birne", tags: ["rezept", "2026"], daysOld: 0.1, kinds: ["text", "image"]), "Küche", []),
            (note("Plan", text: "Code", tags: ["projekt/alpha"], daysOld: 10, kinds: ["code"],
                  props: [NoteProperty(name: "Status", kind: .status, value: "Offen", options: ["Offen"])]), "Projekte/Alpha/Teil", []),
            (note("Alt", text: "nichts", tags: [], daysOld: 400, kinds: []), "", ["code"]),
        ]
    }

    func testSearchMatchesStoredResult() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let text = queries.map { q -> String in
            let f = SearchFilter.parse(q)
            let hits = notes.filter { f.matches($0.0, folderPath: $0.1, kinds: $0.2.isEmpty ? nil : $0.2, now: now) }.map(\.0.title)
            return "\(q.isEmpty ? "(leer)" : q) → \(describe(f)) → \(hits)"
        }.joined(separator: "\n") + "\n"
        try compare(text, with: "search-filters.txt")
    }

    func testFolioLinksMatchStoredResult() throws {
        let links = [
            "folio://note/00000000-0000-0000-0000-000000000001", "folio://note/00000000-0000-0000-0000-000000000001?p=3",
            "folio://note/", "folio://note/kein-uuid", "folio://capture", "folio://capture?text=Hallo%20W%C3%B6rld&target=INBOX",
            "folio://capture?target=00000000-0000-0000-0000-000000000002", "folio://capture?target=falsch", "folio://search?q=%20",
            "folio://search?Q=Apfel", "folio://new?title=T&text=", "folio://open", "folio:", "FOLIO://OPEN", "folio://nix",
            "https://e.example", "folio://search?q=" + String(repeating: "x", count: 100_001),
        ]
        let text = links.map { s -> String in
            guard let url = URL(string: s) else { return "\(s.prefix(40)) → keine URL" }
            switch FolioURL.parse(url) {
            case .success(let action): return "\(s.prefix(70)) → \(action)"
            case .failure(let error): return "\(s.prefix(70)) → \(error)"
            }
        }.joined(separator: "\n") + "\n"
        try compare(text, with: "folio-links.txt")
    }

    private func audio(_ name: String, channels: AVAudioChannelCount, frames: Int, sample: (Int, Int) -> Float) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("folio-\(name)-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        if frames > 0 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for c in 0..<Int(channels) { for i in 0..<frames { buffer.floatChannelData![c][i] = sample(c, i) } }
            try file.write(from: buffer)
        }
        return url
    }

    func testPeaksMatchStoredResult() throws {
        let cases: [(String, AVAudioChannelCount, Int, Int, (Int, Int) -> Float)] = [
            ("leer", 1, 0, 8, { _, _ in 0 }),
            ("kurz", 1, 3, 8, { _, i in Float(i) * 0.1 }),
            ("rampe", 1, 8000, 10, { _, i in Float(i) / 8000 }),
            ("stereo", 2, 4000, 6, { c, i in c == 0 ? 0.1 : (i > 2000 ? -0.6 : 0.2) }),
            ("übersteuert", 1, 1000, 4, { _, i in i % 2 == 0 ? 3 : -5 }),
            ("leise", 1, 800, 4, { _, i in Float(i % 100) * 0.000001 }),
            ("keine buckets", 1, 100, 0, { _, _ in 0.5 }),
        ]
        var lines: [String] = []
        for (name, channels, frames, buckets, sample) in cases {
            let url = try audio(name, channels: channels, frames: frames, sample: sample)
            defer { try? FileManager.default.removeItem(at: url) }
            let peaks = try AudioAnalysis.peaks(of: url, buckets: buckets)
            lines.append("\(name): " + peaks.map { String(format: "%.4f", $0) }.joined(separator: " "))
        }
        try compare(lines.joined(separator: "\n") + "\n", with: "audio-peaks.txt")
    }

    func testUnreadableAudio() {
        XCTAssertThrowsError(try AudioAnalysis.peaks(of: URL(fileURLWithPath: "/nicht/da.wav")))
    }
}

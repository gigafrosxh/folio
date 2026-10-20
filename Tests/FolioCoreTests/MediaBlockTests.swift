import AVFoundation
import XCTest
@testable import FolioCore

final class MediaBlockTests: XCTestCase {
    // MARK: Formula and diagram blocks

    func testRenderCallEscapesSource() throws {
        let source = "a\"b\\c\n</script><script>alert(1)</script>\u{2028}"
        let call = RenderScript.call(.diagram, source: source, options: .init(dark: true, fontSize: 14, displayMode: false))
        XCTAssertTrue(call.hasPrefix("folioRender(\"diagram\", "))
        XCTAssertFalse(call.contains("</script>"), "a closing script tag must never appear literally")
        XCTAssertFalse(call.contains("\u{2028}"))
        XCTAssertTrue(call.contains("\"dark\":true"))
        // The string literal decodes back to the original source.
        let literal = RenderScript.jsString(source).replacingOccurrences(of: "<\\/", with: "</")
        let decoded = try JSONSerialization.jsonObject(with: Data("[\(literal)]".utf8)) as? [String]
        XCTAssertEqual(decoded?.first, source)
    }

    func testRenderResultParsing() {
        let ok = RenderScript.Result(message: ["ok": true, "x": 4, "y": 2, "width": 120.5, "height": 40, "pageHeight": 52, "svg": "<svg/>"])
        XCTAssertEqual(ok?.ok, true)
        XCTAssertEqual(ok?.width, 120.5)
        XCTAssertEqual(ok?.pageHeight, 52)
        XCTAssertEqual(ok?.svg, "<svg/>")
        XCTAssertEqual(ok?.ready, false)

        let failed = RenderScript.Result(message: ["ok": false, "error": "KaTeX parse error: Expected '}'\n\n\nline2\nline3\nline4\nline5"])
        XCTAssertEqual(failed?.ok, false)
        XCTAssertEqual(failed?.error, "Expected '}'\nline2\nline3\nline4")
        XCTAssertNil(RenderScript.Result(message: "nonsense"))
        XCTAssertEqual(RenderScript.Result(message: ["ok": true, "ready": true])?.ready, true)
    }

    func testDiagramType() {
        XCTAssertEqual(RenderSamples.diagramType(of: RenderSamples.diagram), "flowchart")
        XCTAssertEqual(RenderSamples.diagramType(of: "%% Kommentar\n\nsequenceDiagram\n A->>B: x"), "sequenceDiagram")
        XCTAssertEqual(RenderSamples.diagramType(of: "---\ntitle: Ablauf\n---\ngraph TD;\nA-->B"), "graph")
        XCTAssertNil(RenderSamples.diagramType(of: "  \n"))
    }

    func testNewBlockKindsRoundTrip() throws {
        var math = BlockRecord(kind: .math)
        math.code = #"e^{i\pi} + 1 = 0"#
        var diagram = BlockRecord(kind: .diagram)
        diagram.code = RenderSamples.diagram
        var audio = BlockRecord(kind: .audio)
        audio.attachmentID = UUID()
        audio.output = "Hallo Welt"
        audio.language = "de-DE"
        let file = NoteFile(meta: NoteMetadata(title: "Medien"), body: NoteBody(blocks: [math, diagram, audio]))
        let back = try NoteFile.decode(file.encoded())
        XCTAssertEqual(back.body.blocks.map(\.kind), [.math, .diagram, .audio])
        XCTAssertEqual(back.body.blocks[0].code, math.code)
        XCTAssertEqual(back.body.blocks[1].code, RenderSamples.diagram)
        XCTAssertEqual(back.body.blocks[2].output, "Hallo Welt")
        XCTAssertEqual(back.body.blocks[2].language, "de-DE")
    }

    // MARK: Audio

    /// One second of silence, then one second of a 440 Hz tone.
    private func makeTone() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("folio-tone-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
        buffer.frameLength = 32_000
        for i in 0..<32_000 {
            buffer.floatChannelData![0][i] = i < 16_000 ? 0 : 0.5 * sin(Float(i) * 2 * .pi * 440 / 16_000)
        }
        try file.write(from: buffer)
        return url
    }

    func testAudioDurationAndPeaks() throws {
        let url = try makeTone()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try AudioAnalysis.duration(of: url), 2, accuracy: 0.01)
        let peaks = try AudioAnalysis.peaks(of: url, buckets: 10)
        XCTAssertEqual(peaks.count, 10)
        XCTAssertTrue(peaks.prefix(5).allSatisfy { $0 < 0.01 }, "silent half")
        XCTAssertTrue(peaks.suffix(5).allSatisfy { $0 > 0.9 }, "tone half, normalized")
    }

    func testUnreadableAudio() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kein-audio.m4a")
        try? Data("kein Audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try AudioAnalysis.duration(of: url))
        XCTAssertThrowsError(try AudioAnalysis.peaks(of: url))
    }

    func testTimeFormat() {
        XCTAssertEqual(AudioAnalysis.format(0), "0:00")
        XCTAssertEqual(AudioAnalysis.format(65.9), "1:05")
        XCTAssertEqual(AudioAnalysis.format(3723), "1:02:03")
        XCTAssertEqual(AudioAnalysis.format(.nan), "0:00")
    }

    func testTranscriptParagraphs() {
        let text = TranscriptFormatter.join([
            (" Hallo zusammen.", 0, 1.5), ("Heute geht es um Folio.", 1.6, 3), ("", 3, 3),
            ("Nach der Pause.", 8, 9),
        ])
        XCTAssertEqual(text, "Hallo zusammen. Heute geht es um Folio.\n\nNach der Pause.")
    }
}

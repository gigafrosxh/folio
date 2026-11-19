import XCTest
@testable import FolioCore

final class ErduDocumentTests: XCTestCase {
    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tiergarten", withExtension: "erdu", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testValidFileGivesTextAndNames() throws {
        let (text, summary) = try ErduDocument.validate(try fixture())
        XCTAssertTrue(text.contains("\"format\""))
        XCTAssertGreaterThan(summary.entities, 0)
        XCTAssertGreaterThan(summary.tables, 0)
        XCTAssertTrue(summary.names.contains("Mitarbeiter"))
        XCTAssertEqual(summary.names.count, Set(summary.names).count, "names are unique")
        XCTAssertTrue(ErduDocument.searchText(of: text).contains("Mitarbeiter"))
    }

    func testRejectsBrokenOrForeignFiles() throws {
        let good = String(decoding: try fixture(), as: UTF8.self)
        XCTAssertThrowsError(try ErduDocument.validate(Data(good.dropLast(40).utf8))) { XCTAssertEqual($0 as? ErduDocument.Failure, .notJSON) }
        XCTAssertThrowsError(try ErduDocument.validate(Data(#"{"format":"other","version":1}"#.utf8))) { XCTAssertEqual($0 as? ErduDocument.Failure, .notErdu) }
        XCTAssertThrowsError(try ErduDocument.validate(Data(#"{"format":"erd-ultra","version":7}"#.utf8))) { XCTAssertEqual($0 as? ErduDocument.Failure, .newerVersion(7)) }
        XCTAssertThrowsError(try ErduDocument.validate(Data([0xff, 0xfe, 0x00]))) { XCTAssertEqual($0 as? ErduDocument.Failure, .notJSON) }
        XCTAssertThrowsError(try ErduDocument.validate(Data(count: ErduDocument.maxSize + 1))) { XCTAssertEqual($0 as? ErduDocument.Failure, .tooLarge) }
        XCTAssertEqual(ErduDocument.searchText(of: "kaputt"), "")
    }

    func testBlockRoundTrip() throws {
        let text = String(decoding: try fixture(), as: UTF8.self)
        var record = BlockRecord(kind: .erd)
        record.code = text
        record.mode = "rel"
        record.linkedFile = "/Users/x/Uni.erdu"
        let note = NoteFile(meta: NoteMetadata(title: "ER"), body: NoteBody(blocks: [record]))
        let decoded = try NoteFile.decode(note.encoded())
        XCTAssertEqual(decoded.body.blocks.first?.kind, .erd)
        XCTAssertEqual(decoded.body.blocks.first?.code, text)
        XCTAssertEqual(decoded.body.blocks.first?.mode, "rel")
        XCTAssertEqual(decoded.body.blocks.first?.linkedFile, "/Users/x/Uni.erdu")
    }

    func testRenderCallCarriesView() {
        let call = RenderScript.call(.erd, source: "{}", options: RenderScript.Options(view: "sql"))
        XCTAssertTrue(call.hasPrefix("folioRender(\"erd\""))
        XCTAssertTrue(call.contains("\"view\":\"sql\""))
    }
}

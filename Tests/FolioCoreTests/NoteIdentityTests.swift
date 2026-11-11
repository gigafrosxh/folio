import XCTest
@testable import FolioCore

/// Copied note files with the same id (#166).
final class NoteIdentityTests: XCTestCase {
    private let id = UUID()
    private let a = URL(fileURLWithPath: "/lib/A/Original.folio")
    private let b = URL(fileURLWithPath: "/lib/A/Original Kopie.folio")
    private let c = URL(fileURLWithPath: "/lib/B/Original.folio")

    func testKnownFileKeepsTheID() {
        let r = NoteIdentity.resolve([(b, id), (a, id), (c, id)], known: [id: c], created: { _ in Date() })
        XCTAssertEqual(r.keep, [c])
        XCTAssertEqual(r.renew, [b, a])
    }

    func testOldestFileKeepsTheIDThenPath() {
        let dates = [a: Date(timeIntervalSince1970: 20), b: Date(timeIntervalSince1970: 10), c: Date(timeIntervalSince1970: 20)]
        XCTAssertEqual(NoteIdentity.resolve([(a, id), (b, id), (c, id)], created: { dates[$0]! }).keep, [b])
        XCTAssertEqual(NoteIdentity.resolve([(c, id), (a, id)], created: { _ in Date(timeIntervalSince1970: 1) }).keep, [a])
    }

    func testUniqueIDsStayUntouched() {
        let r = NoteIdentity.resolve([(a, UUID()), (b, UUID())])
        XCTAssertEqual(r.keep.count, 2)
        XCTAssertTrue(r.renew.isEmpty)
    }

    func testRenewedKeepsContentWithNewIDs() {
        let att = FolioArchive.Attachment(filename: "a.png", typeIdentifier: "public.png", data: Data([1, 2]))
        var block = BlockRecord(kind: .image)
        block.attachmentID = att.id
        let file = NoteFile(meta: NoteMetadata(title: "Titel", tags: ["x"]), body: NoteBody(blocks: [block]), attachments: [att])
        let renewed = NoteIdentity.renewed(file)
        XCTAssertNotEqual(renewed.meta.id, file.meta.id)
        XCTAssertEqual(renewed.meta.title, "Titel")
        XCTAssertEqual(renewed.meta.tags, ["x"])
        XCTAssertNotEqual(renewed.body.blocks[0].id, block.id)
        XCTAssertNotEqual(renewed.attachments[0].id, att.id)
        XCTAssertEqual(renewed.body.blocks[0].attachmentID, renewed.attachments[0].id)
        XCTAssertEqual(renewed.attachments[0].data, att.data)
    }
}

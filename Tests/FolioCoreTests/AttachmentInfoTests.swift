import XCTest
@testable import FolioCore

final class AttachmentInfoTests: XCTestCase {
    private func attachment(_ name: String, _ type: String, _ data: Data = Data(repeating: 1, count: 2048)) -> FolioArchive.Attachment {
        FolioArchive.Attachment(filename: name, typeIdentifier: type, data: data)
    }

    func testKnownTypeHasNameAndSize() {
        let info = AttachmentInfo(attachment("Bericht.pdf", "com.adobe.pdf"))
        XCTAssertEqual(info.name, "Bericht.pdf")
        XCTAssertFalse(info.typeName.isEmpty)
        XCTAssertEqual(info.byteCount, 2048)
        XCTAssertTrue(info.summary.contains(info.sizeText))
    }

    func testUnknownTypeFallsBackToExtension() {
        XCTAssertEqual(AttachmentInfo(attachment("daten.zzqx", "")).typeName, "ZZQX-Datei")
        XCTAssertEqual(AttachmentInfo(attachment("ohne", "")).typeName, "Unbekannter Dateityp")
        XCTAssertEqual(AttachmentInfo(attachment("   ", "")).name, "Unbenannt")
    }

    func testImageSizeAndBrokenImage() throws {
        // 1×1 PNG
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        XCTAssertEqual(AttachmentInfo(attachment("a.png", "public.png", png)).detail, "1 × 1 Pixel")
        XCTAssertNil(AttachmentInfo(attachment("a.png", "public.png", Data([1, 2, 3]))).detail)
        XCTAssertNil(AttachmentInfo(attachment("leer.pdf", "com.adobe.pdf", Data())).detail)
    }
}

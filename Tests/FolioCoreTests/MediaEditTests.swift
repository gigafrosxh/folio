import CoreGraphics
import CoreText
import ImageIO
import XCTest
@testable import FolioCore

/// Crop and rotation (#45), PDF search text (#43) and the new block fields (#46).
final class MediaEditTests: XCTestCase {
    /// A 4×2 picture: left half red, right half blue.
    private func picture() -> CGImage {
        let ctx = CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        // (A crop test below needs to tell top from bottom: no other colour needed, the halves are left/right.)
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 2, y: 0, width: 2, height: 2))
        return ctx.makeImage()!
    }

    /// Red share of the pixel at (x, y) from the top left.
    private func isRed(_ image: CGImage, _ x: Int, _ y: Int) -> Bool {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = (y * image.width + x) * 4   // bitmap rows run from the top
        return p[i] > 200 && p[i + 2] < 60
    }

    func testRotationTurnsThePicture() throws {
        let img = picture()
        let right = try XCTUnwrap(ImageEdit(quarterTurns: 1).apply(to: img))
        XCTAssertEqual([right.width, right.height], [2, 4])
        XCTAssertTrue(isRed(right, 0, 0), "turned clockwise, the left (red) half is on top")
        XCTAssertFalse(isRed(right, 0, 3))
        let left = try XCTUnwrap(ImageEdit(quarterTurns: 3).apply(to: img))
        XCTAssertFalse(isRed(left, 0, 0), "turned counter-clockwise, red is at the bottom")
        let half = try XCTUnwrap(ImageEdit(quarterTurns: 2).apply(to: img))
        XCTAssertFalse(isRed(half, 0, 0))
        XCTAssertTrue(isRed(half, 3, 1))
        XCTAssertEqual(ImageEdit(quarterTurns: 5).quarterTurns, 1)
        XCTAssertEqual(ImageEdit(quarterTurns: -1).quarterTurns, 3)
    }

    func testCropKeepsThePartAndTurnsWithIt() throws {
        let img = picture()
        let leftHalf = ImageEdit(crop: .init(x: 0, y: 0, width: 0.5, height: 1))
        let cropped = try XCTUnwrap(leftHalf.apply(to: img))
        XCTAssertEqual([cropped.width, cropped.height], [2, 2])
        XCTAssertTrue(isRed(cropped, 1, 1), "only the red half is left")
        // Turning keeps the same part: still only red.
        for turned in [leftHalf.rotated(clockwise: true), leftHalf.rotated(clockwise: false), leftHalf.rotated(clockwise: true).rotated(clockwise: true)] {
            let out = try XCTUnwrap(turned.apply(to: img))
            XCTAssertEqual(out.width * out.height, 4)
            XCTAssertTrue((0..<out.width).allSatisfy { x in (0..<out.height).allSatisfy { isRed(out, x, $0) } }, "\(turned)")
        }
        XCTAssertEqual(leftHalf.rotated(clockwise: true).rotated(clockwise: false), leftHalf)
        XCTAssertEqual(ImageEdit(quarterTurns: 1).outputSize(for: CGSize(width: 400, height: 200)), CGSize(width: 200, height: 400))
    }

    func testCropMeasuresFromTheTop() throws {
        // Turned clockwise, red is on top; the top half of that is all red.
        let top = try XCTUnwrap(ImageEdit(quarterTurns: 1, crop: .init(x: 0, y: 0, width: 1, height: 0.5)).apply(to: picture()))
        XCTAssertEqual([top.width, top.height], [2, 2])
        XCTAssertTrue((0..<2).allSatisfy { x in (0..<2).allSatisfy { isRed(top, x, $0) } })
        let bottom = try XCTUnwrap(ImageEdit(quarterTurns: 1, crop: .init(x: 0, y: 0.5, width: 1, height: 0.5)).apply(to: picture()))
        XCTAssertFalse(isRed(bottom, 0, 0))
    }

    func testFourTurnsKeepTheSameCrop() throws {
        // #203
        let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let img = ctx.makeImage()!
        var edit = ImageEdit(crop: .init(x: 0.1, y: 0.2, width: 0.5, height: 0.5))
        let before = try XCTUnwrap(edit.apply(to: img))
        for _ in 0..<4 { edit = edit.rotated(clockwise: true) }
        let after = try XCTUnwrap(edit.apply(to: img))
        XCTAssertEqual([after.width, after.height], [before.width, before.height])
        XCTAssertEqual([before.width, before.height], [20, 10])
        for _ in 0..<7 { edit = edit.rotated(clockwise: false) }
        let odd = try XCTUnwrap(edit.apply(to: img))
        XCTAssertEqual([odd.width, odd.height], [10, 20], "an odd number of turns swaps the sides exactly")
    }

    func testCameraOrientationIsTheStartingPoint() throws {
        // #201: a 40×20 JPEG stored sideways (EXIF orientation 6) is shown 20×40.
        let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let jpeg = out as Data
        let shown = try XCTUnwrap(ImageEdit.orientedImage(from: jpeg))
        XCTAssertEqual([shown.width, shown.height], [20, 40])
        let turned = try XCTUnwrap(ImageEdit(quarterTurns: 1).renderedPNG(from: jpeg))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(turned as CFData, nil))
        let png = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual([png.width, png.height], [40, 20], "one turn from what is shown")
    }

    func testCropIsKeptInsideAndFullMeansNone() {
        let c = ImageEdit.CropRect(x: 0.9, y: -0.5, width: 0.5, height: 0.001).clamped
        XCTAssertEqual(c.x + c.width, 1, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0)
        XCTAssertEqual(c.height, 0.02, accuracy: 1e-9)
        XCTAssertNil(ImageEdit(crop: .full).crop)
        XCTAssertTrue(ImageEdit(quarterTurns: 4, crop: .full).isIdentity)
        XCTAssertNil(ImageEdit().renderedPNG(from: Data("kein Bild".utf8)))
    }

    /// A one-page PDF with `text`.
    private func pdf(_ text: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)]))
        ctx.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    func testPDFTextIsIndexedOnceAndKeepsTheDate() throws {
        XCTAssertTrue(PDFSearchText.of(pdf("Photosynthese im Chloroplast")).contains("Photosynthese"))
        XCTAssertEqual(PDFSearchText.of(Data("kein pdf".utf8)), "")
        let att = FolioArchive.Attachment(filename: "Bio.pdf", typeIdentifier: "com.adobe.pdf", data: pdf("Photosynthese im Chloroplast"))
        var block = BlockRecord(kind: .pdf)
        block.attachmentID = att.id
        let date = Date(timeIntervalSince1970: 1_000)
        var file = NoteFile(meta: NoteMetadata(title: "Bio", modified: date, searchText: "Bio"), body: NoteBody(blocks: [block]), attachments: [att])
        XCTAssertTrue(file.indexPDFText())
        XCTAssertTrue(file.meta.searchText.contains("Photosynthese"))
        XCTAssertEqual(file.meta.modified, date)
        XCTAssertFalse(file.indexPDFText(), "the second time there is nothing to do")
        let again = try NoteFile.decode(file.encoded())
        XCTAssertTrue(again.body.blocks[0].pdfText?.contains("Chloroplast") == true)
    }

    func testOlderFilesWithoutTheNewFieldsStillLoad() throws {
        var block = BlockRecord(kind: .image)
        block.altText = "Ein rotes Haus"
        block.imageEdit = ImageEdit(quarterTurns: 1, crop: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        let json = try JSONEncoder().encode(block)
        XCTAssertEqual(try JSONDecoder().decode(BlockRecord.self, from: json).imageEdit, block.imageEdit)
        let old = try JSONDecoder().decode(BlockRecord.self, from: Data(#"{"id":"\#(UUID())","kind":"image","caption":"x"}"#.utf8))
        XCTAssertNil(old.altText)
        XCTAssertNil(old.imageEdit)
        XCTAssertNil(old.pdfText)
    }
}

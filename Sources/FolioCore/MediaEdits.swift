import CoreGraphics
import Foundation
import ImageIO

// MARK: - Image crop and rotation (#45)

/// A non-destructive edit of an image block: the attachment keeps the original, the block stores how to show it.
public struct ImageEdit: Codable, Equatable, Sendable {
    /// Quarter turns clockwise, 0…3.
    public var quarterTurns: Int
    /// The visible part of the rotated image, in fractions of its width and height (0…1); nil = all of it.
    public var crop: CropRect?

    public struct CropRect: Codable, Equatable, Sendable {
        public var x: Double, y: Double, width: Double, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }

        /// Kept inside the image and at least 2 % in each direction, so a crop never makes the picture vanish.
        public var clamped: CropRect {
            let minSize = 0.02
            let w = min(max(width, minSize), 1), h = min(max(height, minSize), 1)
            return CropRect(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - h), width: w, height: h)
        }

        public static let full = CropRect(x: 0, y: 0, width: 1, height: 1)
        public var isFull: Bool { abs(x) < 1e-6 && abs(y) < 1e-6 && abs(width - 1) < 1e-6 && abs(height - 1) < 1e-6 }
    }

    public init(quarterTurns: Int = 0, crop: CropRect? = nil) {
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.crop = crop.map(\.clamped).flatMap { $0.isFull ? nil : $0 }
    }

    public var isIdentity: Bool { quarterTurns == 0 && crop == nil }

    /// Turning keeps the same part of the picture: the crop turns with it.
    public func rotated(clockwise: Bool) -> ImageEdit {
        guard let c = crop else { return ImageEdit(quarterTurns: quarterTurns + (clockwise ? 1 : -1)) }
        let turned = clockwise
            ? CropRect(x: 1 - c.y - c.height, y: c.x, width: c.height, height: c.width)
            : CropRect(x: c.y, y: 1 - c.x - c.width, width: c.height, height: c.width)
        return ImageEdit(quarterTurns: quarterTurns + (clockwise ? 1 : -1), crop: turned)
    }

    /// Size of the shown picture for an original of `size`.
    public func outputSize(for size: CGSize) -> CGSize {
        let turned = quarterTurns % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
        let c = crop ?? .full
        return CGSize(width: max(1, (turned.width * c.width).rounded()), height: max(1, (turned.height * c.height).rounded()))
    }

    /// The edited picture. Crop fractions use a top-left origin, like the editor shows them.
    public func apply(to image: CGImage) -> CGImage? {
        guard !isIdentity else { return image }
        let w = image.width, h = image.height
        let turnedW = quarterTurns % 2 == 1 ? h : w, turnedH = quarterTurns % 2 == 1 ? w : h
        guard let ctx = CGContext(data: nil, width: turnedW, height: turnedH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        // Clockwise turns in a bottom-left coordinate system.
        switch quarterTurns {
        case 1: ctx.translateBy(x: 0, y: CGFloat(turnedH)); ctx.rotate(by: -.pi / 2)
        case 2: ctx.translateBy(x: CGFloat(turnedW), y: CGFloat(turnedH)); ctx.rotate(by: .pi)
        case 3: ctx.translateBy(x: CGFloat(turnedW), y: 0); ctx.rotate(by: .pi / 2)
        default: break
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let turned = ctx.makeImage() else { return nil }
        guard let c = crop else { return turned }
        let rect = CGRect(x: c.x * Double(turnedW), y: c.y * Double(turnedH), width: c.width * Double(turnedW), height: c.height * Double(turnedH)).integral
        return turned.cropping(to: rect.intersection(CGRect(x: 0, y: 0, width: turnedW, height: turnedH)))
    }

    /// PNG of the edited picture (for exports); nil when the data is no picture.
    public func renderedPNG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let edited = apply(to: image) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, edited, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

// MARK: - PDF text for search (#43)

public enum PDFSearchText {
    /// Upper bound of indexed text per PDF; long books are still found by their first part.
    public static let maxCharacters = 200_000

    /// The text of a PDF for the note search, page after page; "" for scans, locked or broken files.
    public static func of(_ data: Data) -> String {
        guard let result = try? PDFText.extract(from: data, maxCharacters: maxCharacters) else { return "" }
        let text = result.pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > maxCharacters ? String(text.prefix(maxCharacters)) : text
    }
}

extension NoteFile {
    /// Gives PDF blocks without search text their text and adds it to the note's search text, keeping the
    /// modification date (#43). False when there was nothing to do.
    public mutating func indexPDFText() -> Bool {
        var added: [String] = []
        var changed = false
        for i in body.blocks.indices where body.blocks[i].kind == .pdf && body.blocks[i].pdfText == nil {
            guard let id = body.blocks[i].attachmentID, let att = attachments.first(where: { $0.id == id }) else { continue }
            let text = PDFSearchText.of(att.data)
            body.blocks[i].pdfText = text
            changed = true
            if !text.isEmpty { added.append(text) }
        }
        guard changed else { return false }
        if !added.isEmpty { meta.searchText += "\n" + added.joined(separator: "\n") }
        return true
    }
}

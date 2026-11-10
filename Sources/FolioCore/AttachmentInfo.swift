import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Name, type and size of an attachment in words for the note (#49).
public struct AttachmentInfo: Hashable, Sendable {
    public var name: String
    public var typeName: String
    public var byteCount: Int
    public var sizeText: String
    /// Pixel size of an image or page count of a PDF, when they can be read.
    public var detail: String?

    public init(_ attachment: FolioArchive.Attachment) {
        let header = attachment.header
        let trimmed = header.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        name = trimmed.isEmpty ? "Unbenannt" : trimmed
        let fileExtension = (trimmed as NSString).pathExtension
        let type = Self.type(identifier: header.typeIdentifier, fileExtension: fileExtension)
        if let description = type?.localizedDescription, !description.isEmpty {
            typeName = description
        } else if !fileExtension.isEmpty {
            typeName = "\(fileExtension.uppercased())-Datei"
        } else {
            typeName = "Unbekannter Dateityp"
        }
        byteCount = attachment.data.count
        sizeText = ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)
        detail = attachment.data.isEmpty || header.isPackage ? nil : Self.detail(of: attachment.data, type: type)
    }

    /// Everything but the name, for showing next to it.
    public var summary: String {
        [typeName, sizeText, detail].compactMap { $0 }.joined(separator: " · ")
    }

    private static func type(identifier: String, fileExtension: String) -> UTType? {
        if let type = UTType(identifier), !type.isDynamic { return type }
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension), !type.isDynamic else { return nil }
        return type
    }

    private static func detail(of data: Data, type: UTType?) -> String? {
        guard let type else { return nil }
        if type.conforms(to: .image) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return "\(width) × \(height) Pixel"
        }
        if type.conforms(to: .pdf) {
            guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider) else { return nil }
            return pdf.numberOfPages == 1 ? "1 Seite" : "\(pdf.numberOfPages) Seiten"
        }
        return nil
    }
}

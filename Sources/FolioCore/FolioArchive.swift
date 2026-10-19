import Foundation

/// The `.folio` container: a small binary envelope around LZFSE-compressed sections.
///
/// Layout (all integers little endian):
///
///     magic        "FOLI"            4 bytes
///     version      UInt16            currently 1
///     flags        UInt16            bit 0 = LZFSE compression
///     meta         section           note metadata JSON (title, tags, dates …)
///     body         section           block JSON (text as RTF, code, embeds …)
///     count        UInt32            number of attachments
///     attachments  count × (UInt32 header length, header JSON, section)
///     checksum     UInt32            CRC-32 over everything before it
///
///     section  =   UInt64 raw length, UInt64 stored length, stored bytes
///
/// Metadata comes first so the note list can be built by reading only the head of each file.
public struct FolioArchive: Sendable {
    public static let magic: [UInt8] = Array("FOLI".utf8)
    public static let currentVersion: UInt16 = 1
    public static let fileExtension = "folio"

    public struct AttachmentHeader: Codable, Sendable {
        public var id: UUID
        public var filename: String
        public var typeIdentifier: String
        /// `true` when `data` is a serialized `FileWrapper` (packages such as .numbers or .pages).
        public var isPackage: Bool
    }

    public struct Attachment: Sendable {
        public var header: AttachmentHeader
        public var data: Data

        public init(id: UUID = UUID(), filename: String, typeIdentifier: String, isPackage: Bool = false, data: Data) {
            self.header = AttachmentHeader(id: id, filename: filename, typeIdentifier: typeIdentifier, isPackage: isPackage)
            self.data = data
        }

        public var id: UUID { header.id }
    }

    public var meta: Data
    public var body: Data
    public var attachments: [Attachment]

    public init(meta: Data, body: Data, attachments: [Attachment] = []) {
        self.meta = meta
        self.body = body
        self.attachments = attachments
    }

    // MARK: Encoding

    public func encoded() throws -> Data {
        var w = ByteWriter()
        w.append(FolioArchive.magic)
        w.append(UInt16(FolioArchive.currentVersion))
        w.append(UInt16(1)) // LZFSE
        try w.appendSection(meta)
        try w.appendSection(body)
        w.append(UInt32(attachments.count))
        let encoder = JSONEncoder()
        for attachment in attachments {
            let header = try encoder.encode(attachment.header)
            w.append(UInt32(header.count))
            w.append(header)
            try w.appendSection(attachment.data)
        }
        w.append(CRC32.checksum(w.data))
        return w.data
    }

    // MARK: Decoding

    public static func decode(_ data: Data, metaOnly: Bool = false) throws -> FolioArchive {
        var r = ByteReader(data)
        guard try r.readBytes(4) == magic else { throw FolioFormatError.badMagic }
        let version: UInt16 = try r.read()
        guard version <= currentVersion else { throw FolioFormatError.unsupportedVersion(version) }
        let flags: UInt16 = try r.read()
        let compressed = flags & 1 == 1
        let meta = try r.readSection(compressed: compressed)
        if metaOnly { return FolioArchive(meta: meta, body: Data()) }

        guard data.count >= 4 else { throw FolioFormatError.truncated }
        let payload = data.prefix(data.count - 4)
        var tail = ByteReader(data.suffix(4))
        let stored: UInt32 = try tail.read()
        guard CRC32.checksum(payload) == stored else { throw FolioFormatError.checksumMismatch }

        let body = try r.readSection(compressed: compressed)
        let count: UInt32 = try r.read()
        var attachments: [Attachment] = []
        let decoder = JSONDecoder()
        for _ in 0..<count {
            let headerLength: UInt32 = try r.read()
            let header = try decoder.decode(AttachmentHeader.self, from: Data(try r.readBytes(Int(headerLength))))
            let content = try r.readSection(compressed: compressed)
            attachments.append(Attachment(header: header, data: content))
        }
        return FolioArchive(meta: meta, body: body, attachments: attachments)
    }

    /// Reads only the metadata section, memory-mapping the file so the body is never touched.
    public static func readMeta(at url: URL) throws -> Data {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try decode(data, metaOnly: true).meta
    }
}

extension FolioArchive.Attachment {
    init(header: FolioArchive.AttachmentHeader, data: Data) {
        self.header = header
        self.data = data
    }
}

public enum FolioFormatError: Error, LocalizedError, Equatable {
    case badMagic
    case unsupportedVersion(UInt16)
    case truncated
    case checksumMismatch
    case compressionFailed

    public var errorDescription: String? {
        switch self {
        case .badMagic: return "Keine Folio-Notiz (falsche Dateikennung)."
        case .unsupportedVersion(let v): return "Dateiversion \(v) wird nicht unterstützt."
        case .truncated: return "Die Datei ist unvollständig."
        case .checksumMismatch: return "Die Prüfsumme stimmt nicht – die Datei ist beschädigt."
        case .compressionFailed: return "Komprimierung fehlgeschlagen."
        }
    }
}

// MARK: - Byte helpers

private enum Codec {
    static func compress(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }
        do { return try (data as NSData).compressed(using: .lzfse) as Data } catch { throw FolioFormatError.compressionFailed }
    }

    static func decompress(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }
        do { return try (data as NSData).decompressed(using: .lzfse) as Data } catch { throw FolioFormatError.compressionFailed }
    }
}

struct ByteWriter {
    var data = Data()

    mutating func append(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
    mutating func append(_ bytes: Data) { data.append(bytes) }
    mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func appendSection(_ raw: Data) throws {
        let stored = try Codec.compress(raw)
        append(UInt64(raw.count))
        append(UInt64(stored.count))
        append(stored)
    }
}

struct ByteReader {
    private let bytes: Data
    private var offset: Int

    init(_ data: Data) {
        bytes = data
        offset = data.startIndex
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.endIndex else { throw FolioFormatError.truncated }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func read<T: FixedWidthInteger>() throws -> T {
        let raw = try readBytes(MemoryLayout<T>.size)
        var value: T = 0
        for (i, byte) in raw.enumerated() { value |= T(byte) << (8 * i) }
        return value
    }

    mutating func readSection(compressed: Bool) throws -> Data {
        let rawLength: UInt64 = try read()
        let storedLength: UInt64 = try read()
        guard storedLength <= UInt64(Int.max) else { throw FolioFormatError.truncated }
        let stored = Data(try readBytes(Int(storedLength)))
        let raw = compressed ? try Codec.decompress(stored) : stored
        guard raw.count == rawLength else { throw FolioFormatError.truncated }
        return raw
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

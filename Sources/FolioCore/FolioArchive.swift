import Compression
import Foundation

/// The `.folio` container: a small binary envelope around LZFSE-compressed sections.
///
/// Layout (all integers little endian):
///
///     magic        "FOLI"            4 bytes
///     version      UInt16            currently 1
///     flags        UInt16            bit 0 = LZFSE compression; other bits are reserved and rejected (#276)
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
    /// Flag bits this version understands; a file with any other bit set needs a newer Folio (#276).
    public static let knownFlags: UInt16 = 1

    /// How much of a file was checked when it was read (#275).
    public enum Integrity: Sendable, Equatable {
        /// Only the header and metadata were read (note list); body, attachments and checksum are not verified.
        case headerOnly
        /// Every section was read and the checksum matched.
        case verified
    }

    public struct AttachmentHeader: Codable, Sendable, Equatable {
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
    /// `.headerOnly` after `decode(_:metaOnly: true)`: a damaged body is only found when the note is opened (#275).
    public private(set) var integrity: Integrity = .verified

    public init(meta: Data, body: Data, attachments: [Attachment] = []) {
        self.meta = meta
        self.body = body
        self.attachments = attachments
    }

    // MARK: Encoding

    /// Refuses (before anything is written) what `decode` would refuse, so a save can never produce a file Folio cannot
    /// open again; the caller keeps the previous file (#272).
    public func encoded() throws -> Data {
        guard UInt32(exactly: attachments.count).map({ $0 <= ArchiveLimits.maxAttachments }) == true else { throw FolioFormatError.tooLarge }
        let total = ([meta, body] + attachments.map(\.data)).reduce(UInt64(0)) { $0 + UInt64($1.count) }
        guard total <= ArchiveLimits.maxTotal else { throw FolioFormatError.tooLarge }
        var w = ByteWriter()
        w.append(FolioArchive.magic)
        w.append(UInt16(FolioArchive.currentVersion))
        w.append(UInt16(1))  // LZFSE
        try w.appendSection(meta)
        try w.appendSection(body)
        w.append(UInt32(attachments.count))
        let encoder = JSONEncoder()
        for attachment in attachments {
            let header = try encoder.encode(attachment.header)
            guard header.count <= ArchiveLimits.maxAttachmentHeader else { throw FolioFormatError.tooLarge }
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
        guard flags & ~knownFlags == 0 else { throw FolioFormatError.unsupportedFlags(flags) }
        let compressed = flags & 1 == 1
        let meta = try r.readSection(compressed: compressed)
        if metaOnly {
            var archive = FolioArchive(meta: meta, body: Data())
            archive.integrity = .headerOnly
            return archive
        }

        guard data.count >= 4 else { throw FolioFormatError.truncated }
        let payload = data.prefix(data.count - 4)
        var tail = ByteReader(data.suffix(4))
        let stored: UInt32 = try tail.read()
        guard CRC32.checksum(payload) == stored else { throw FolioFormatError.checksumMismatch }
        // Everything after the metadata is read from the payload only, never from the checksum bytes (#277).
        r.limit(to: payload.endIndex)

        let body = try r.readSection(compressed: compressed)
        let count: UInt32 = try r.read()
        guard count <= ArchiveLimits.maxAttachments else { throw FolioFormatError.tooLarge }
        var attachments: [Attachment] = []
        let decoder = JSONDecoder()
        for _ in 0..<count {
            let headerLength: UInt32 = try r.read()
            guard headerLength <= ArchiveLimits.maxAttachmentHeader else { throw FolioFormatError.tooLarge }
            let header = try decoder.decode(AttachmentHeader.self, from: Data(try r.readBytes(Int(headerLength))))
            let content = try r.readSection(compressed: compressed)
            attachments.append(Attachment(header: header, data: content))
        }
        // The last attachment ends exactly where the checksum begins (#277).
        guard r.isAtEnd else { throw FolioFormatError.trailingBytes }
        return FolioArchive(meta: meta, body: body, attachments: attachments)
    }

    /// Reads only the metadata section, memory-mapping the file so the body is never touched. The rest of the file is
    /// not checked here (`Integrity.headerOnly`); opening the note verifies it (#275).
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
    /// A section or attachment count beyond `ArchiveLimits` (#161).
    case tooLarge
    /// Flag bits this version does not know (#276).
    case unsupportedFlags(UInt16)
    /// Bytes left between the last attachment and the checksum (#277).
    case trailingBytes

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "Die Datei gibt unglaubwürdig große Inhalte an und wird nicht geöffnet."
        case .badMagic: return "Keine Folio-Notiz (falsche Dateikennung)."
        case .unsupportedVersion(let v): return "Dateiversion \(v) wird nicht unterstützt."
        case .truncated: return "Die Datei ist unvollständig."
        case .checksumMismatch: return "Die Prüfsumme stimmt nicht – die Datei ist beschädigt."
        case .compressionFailed: return "Komprimierung fehlgeschlagen."
        case .unsupportedFlags(let f): return "Die Datei nutzt Funktionen (Kennung \(f)), die diese Folio-Version nicht kennt. Bitte Folio aktualisieren."
        case .trailingBytes: return "Die Datei enthält unerwartete Daten am Ende – sie ist beschädigt."
        }
    }
}

// MARK: - Byte helpers

private enum Codec {
    static func compress(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }
        do { return try (data as NSData).compressed(using: .lzfse) as Data } catch { throw FolioFormatError.compressionFailed }
    }

    /// Unpacks into a buffer of exactly the size the file states, so a forged file can never grow beyond it (#161).
    static func decompress(_ data: Data, size: Int) throws -> Data {
        if data.isEmpty || size == 0 { return Data() }
        // One byte more than stated: if it gets filled, the file holds more than it claims.
        var out = Data(count: size + 1)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, size + 1,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written == size else { throw FolioFormatError.compressionFailed }
        out.removeLast()
        return out
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
        // Same limits as `ByteReader.readSection`, so every saved note opens again (#272).
        guard UInt64(raw.count) <= ArchiveLimits.maxSection else { throw FolioFormatError.tooLarge }
        let stored = try Codec.compress(raw)
        guard ArchiveLimits.allows(raw: UInt64(raw.count), stored: UInt64(stored.count)) else { throw FolioFormatError.tooLarge }
        append(UInt64(raw.count))
        append(UInt64(stored.count))
        append(stored)
    }
}

struct ByteReader {
    private let bytes: Data
    private var offset: Int
    /// End of the readable range (the payload before the checksum, once `limit(to:)` is called).
    private var end: Int
    /// Bytes unpacked so far, against `ArchiveLimits.maxTotal`.
    private var unpacked: UInt64 = 0

    init(_ data: Data) {
        bytes = data
        offset = data.startIndex
        end = data.endIndex
    }

    var isAtEnd: Bool { offset == end }

    mutating func limit(to index: Int) { end = min(max(index, offset), bytes.endIndex) }

    /// A slice of the input without copying it (#306).
    mutating func readData(_ count: Int) throws -> Data {
        guard count >= 0, count <= end - offset else { throw FolioFormatError.truncated }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        // Compared by subtraction: `offset + count` could overflow for a forged length (#273).
        guard count >= 0, count <= end - offset else { throw FolioFormatError.truncated }
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
        guard let storedCount = Int(exactly: storedLength) else { throw FolioFormatError.truncated }
        guard !compressed || ArchiveLimits.allows(raw: rawLength, stored: storedLength),
            rawLength <= ArchiveLimits.maxTotal - unpacked
        else { throw FolioFormatError.tooLarge }
        unpacked += rawLength
        // Unpacked straight from the input; only uncompressed sections are copied (into a zero-based Data) (#306).
        let stored = try readData(storedCount)
        guard let rawCount = Int(exactly: rawLength) else { throw FolioFormatError.tooLarge }
        let raw = compressed ? try Codec.decompress(stored, size: rawCount) : Data(stored)
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

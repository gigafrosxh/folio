import Foundation

/// Decodes UTF-8 that arrives in chunks: a character split between two chunks is held back until it is complete, so
/// umlauts and emoji never turn into replacement characters at a chunk border (#294).
public struct UTF8Stream: Sendable {
    private var pending = Data()

    public init() {}

    /// Text of everything complete so far.
    public mutating func decode(_ chunk: Data) -> String {
        pending.append(chunk)
        let complete = Self.completeLength(pending)
        let text = String(decoding: pending.prefix(complete), as: UTF8.self)
        pending = Data(pending.dropFirst(complete))
        return text
    }

    /// Whatever is left at the end (an incomplete character becomes a replacement character).
    public mutating func flush() -> String {
        defer { pending = Data() }
        return String(decoding: pending, as: UTF8.self)
    }

    /// Length of the prefix of `data` that does not end inside a multi-byte character.
    public static func completeLength(_ data: Data) -> Int {
        let bytes = [UInt8](data.suffix(3))
        let count = data.count
        // Walk back over continuation bytes (10xxxxxx) to the lead byte of the last character.
        var back = 0
        while back < bytes.count, bytes[bytes.count - 1 - back] & 0xC0 == 0x80 { back += 1 }
        guard back < bytes.count else { return count }
        let lead = bytes[bytes.count - 1 - back]
        let needed: Int
        switch lead {
        case 0xC0...0xDF: needed = 2
        case 0xE0...0xEF: needed = 3
        case 0xF0...0xF7: needed = 4
        default: return count  // ASCII or an invalid byte: nothing to wait for
        }
        return back + 1 < needed ? count - back - 1 : count
    }
}

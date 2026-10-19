import Foundation

/// Finds `#tags` in plain text. A tag starts with a letter, may contain letters, digits, `_`, `-` and `/`
/// (for nested tags like `#projekt/notes`), and must not be glued to a preceding word (`C#`, `a#b`).
public enum TagParser {
    public struct Match: Sendable, Equatable {
        public var tag: String
        /// Range of the whole token including `#`, in UTF-16 units.
        public var range: NSRange
    }

    private static let regex = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_#&/])#(\p{L}[\p{L}\p{N}_\-/]*)"#
    )

    public static func matches(in text: String) -> [Match] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            var tag = ns.substring(with: m.range(at: 1))
            while let last = tag.last, "-/".contains(last) { tag.removeLast() }
            guard !tag.isEmpty else { return nil }
            let length = 1 + (tag as NSString).length
            return Match(tag: tag, range: NSRange(location: m.range.location, length: length))
        }
    }

    /// Unique, lowercased tags in order of first appearance.
    public static func tags(in text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for m in matches(in: text) {
            let key = m.tag.lowercased()
            if seen.insert(key).inserted { result.append(key) }
        }
        return result
    }
}

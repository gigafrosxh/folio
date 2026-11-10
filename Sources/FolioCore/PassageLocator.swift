import Foundation

/// Finds a cited passage in a block's text (#35, #143): its first line is looked up, and the selection reaches
/// to its last line as far as the passage is contiguous.
public enum PassageLocator {
    public struct Match: Equatable, Sendable {
        public var range: NSRange
        /// Length of the part that matched the first line, for the find indicator.
        public var firstLineLength: Int
    }

    /// The lines of a passage that are long enough to search for.
    public static func searchLines(of passage: String) -> [String] {
        passage.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 }
    }

    public static func locate(_ lines: [String], in text: String) -> Match? {
        guard let first = lines.first else { return nil }
        let ns = text as NSString
        let start = ns.range(of: String(first.prefix(60)), options: [.caseInsensitive, .diacriticInsensitive])
        guard start.location != NSNotFound else { return nil }
        let end = endOfPassage(lines, startingAt: start, in: ns)
        return Match(range: NSRange(location: start.location, length: end - start.location), firstLineLength: start.length)
    }

    private static func endOfPassage(_ lines: [String], startingAt start: NSRange, in ns: NSString) -> Int {
        guard let last = lines.last, last != lines.first else { return NSMaxRange(start) }
        let rest = NSRange(location: start.location, length: ns.length - start.location)
        let found = ns.range(of: String(last.suffix(60)), options: [.caseInsensitive], range: rest)
        return found.location != NSNotFound && NSMaxRange(found) - start.location < 4000 ? NSMaxRange(found) : NSMaxRange(start)
    }
}

import Foundation

/// Document order, including non-text blocks. Text ranges use NSTextStorage's UTF-16 coordinates.
public struct NoteOutline {
    public enum Level: Int, Codable, Sendable { case title = 1, heading, subheading }

    public struct Paragraph {
        public let blockID: UUID
        public let kind: BlockKind
        public let range: NSRange
        public let level: Level?
        public let title: String

        public init(blockID: UUID, kind: BlockKind, range: NSRange, level: Level? = nil, title: String = "") {
            self.blockID = blockID
            self.kind = kind
            self.range = range
            self.level = level
            self.title = title
        }
    }

    /// Character offsets change when typing above a heading. Count only identical headings in its block.
    public struct Heading: Hashable, Codable, Sendable {
        public let blockID: UUID
        public let title: String
        public let level: Level
        public let occurrence: Int
    }

    public struct Section {
        public let heading: Heading
        public let start: Paragraph
        public let end: Paragraph
        /// Indices of everything below the heading, up to (but excluding) the next peer or ancestor.
        public let content: Range<Int>
    }

    public let paragraphs: [Paragraph]
    public let sections: [Section]

    public init(_ paragraphs: [Paragraph]) {
        self.paragraphs = paragraphs
        var occurrences: [Heading: Int] = [:]
        var next = [Int](repeating: paragraphs.count, count: 4)
        var ends: [Int: Int] = [:]
        for i in paragraphs.indices.reversed() {
            guard let level = paragraphs[i].level else { continue }
            ends[i] = next[level.rawValue]
            for depth in level.rawValue...3 { next[depth] = i }
        }
        self.sections = paragraphs.indices.compactMap { i in
            let p = paragraphs[i]
            guard let level = p.level, let end = ends[i] else { return nil }
            let key = Heading(blockID: p.blockID, title: p.title, level: level, occurrence: 0)
            let n = occurrences[key, default: 0]
            occurrences[key] = n + 1
            let heading = Heading(blockID: p.blockID, title: p.title, level: level, occurrence: n)
            return Section(heading: heading, start: p, end: paragraphs[end - 1], content: (i + 1)..<end)
        }
    }
}

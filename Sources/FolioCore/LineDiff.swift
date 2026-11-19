import Foundation

public enum LineDiff {
    public struct Line: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case same, added, removed }
        public var kind: Kind
        public var text: String
        public var oldNumber: Int?
        public var newNumber: Int?
        public var hasTrailingNewline: Bool

        public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?, hasTrailingNewline: Bool = true) {
            self.kind = kind
            self.text = text
            self.oldNumber = oldNumber
            self.newNumber = newNumber
            self.hasTrailingNewline = hasTrailingNewline
        }
    }

    public struct Hunk: Equatable, Sendable {
        public var oldStart: Int
        public var oldCount: Int
        public var newStart: Int
        public var newCount: Int
        public var lines: [Line]

        public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [Line]) {
            self.oldStart = oldStart
            self.oldCount = oldCount
            self.newStart = newStart
            self.newCount = newCount
            self.lines = lines
        }
    }

    private static func split(_ text: String) -> [String] {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        let terminated = text.hasSuffix("\n")
        if terminated { lines.removeLast() }
        return lines.enumerated().map { index, line in
            line + (terminated || index < lines.count - 1 ? "\n" : "")
        }
    }

    public static func diff(old: String, new: String) -> [Line] {
        let a = split(old), b = split(new)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix,
              a[a.count - suffix - 1] == b[b.count - suffix - 1] { suffix += 1 }
        let left = Array(a[prefix..<(a.count - suffix)])
        let right = Array(b[prefix..<(b.count - suffix)])
        let kinds = Array(repeating: Line.Kind.same, count: prefix)
            + middleKinds(left, right) + Array(repeating: .same, count: suffix)
        var i = 0, j = 0
        return kinds.map { kind in
            let raw = kind == .added ? b[j] : a[i]
            let line = Line(kind: kind, text: raw.hasSuffix("\n") ? String(raw.dropLast()) : raw,
                            oldNumber: kind == .added ? nil : i + 1,
                            newNumber: kind == .removed ? nil : j + 1,
                            hasTrailingNewline: raw.hasSuffix("\n"))
            if kind != .added { i += 1 }
            if kind != .removed { j += 1 }
            return line
        }
    }

    // Bound both time and memory; large replacements retain their common prefix and suffix.
    private static func middleKinds(_ a: [String], _ b: [String]) -> [Line.Kind] {
        guard !a.isEmpty, !b.isEmpty, a.count <= 1_000_000 / b.count else {
            return Array(repeating: .removed, count: a.count) + Array(repeating: .added, count: b.count)
        }
        let width = b.count + 1
        var lengths = Array(repeating: 0, count: (a.count + 1) * width)
        for i in (0..<a.count).reversed() {
            for j in (0..<b.count).reversed() {
                lengths[i * width + j] = a[i] == b[j]
                    ? 1 + lengths[(i + 1) * width + j + 1]
                    : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
            }
        }
        return trace(a, b, lengths: lengths, width: width)
    }

    private static func trace(_ a: [String], _ b: [String], lengths: [Int], width: Int) -> [Line.Kind] {
        var result: [Line.Kind] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                result.append(.same)
                i += 1
                j += 1
            } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
                result.append(.removed)
                i += 1
            } else {
                result.append(.added)
                j += 1
            }
        }
        return result + Array(repeating: .removed, count: a.count - i)
            + Array(repeating: .added, count: b.count - j)
    }

    public static func hunks(_ lines: [Line], context: Int = 3) -> [Hunk] {
        let context = min(max(0, context), lines.count)
        var ranges: [Range<Int>] = []
        for index in lines.indices where lines[index].kind != .same {
            let range = max(0, index - context)..<(index + min(context, lines.count - index - 1) + 1)
            if let last = ranges.last, range.lowerBound <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        var oldOffsets = [0], newOffsets = [0]
        for line in lines {
            oldOffsets.append(oldOffsets.last! + (line.kind == .added ? 0 : 1))
            newOffsets.append(newOffsets.last! + (line.kind == .removed ? 0 : 1))
        }
        return ranges.map { range in
            let oldCount = oldOffsets[range.upperBound] - oldOffsets[range.lowerBound]
            let newCount = newOffsets[range.upperBound] - newOffsets[range.lowerBound]
            return Hunk(oldStart: oldOffsets[range.lowerBound] + (oldCount == 0 ? 0 : 1), oldCount: oldCount,
                        newStart: newOffsets[range.lowerBound] + (newCount == 0 ? 0 : 1), newCount: newCount,
                        lines: Array(lines[range]))
        }
    }

    public static func unified(old: String, new: String, oldName: String, newName: String, context: Int = 3) -> String {
        let hunks = hunks(diff(old: old, new: new), context: context)
        guard !hunks.isEmpty else { return "" }
        var result = "--- \(oldName)\n+++ \(newName)\n"
        for hunk in hunks {
            result += "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@\n"
            for line in hunk.lines {
                let prefix = line.kind == .same ? " " : line.kind == .added ? "+" : "-"
                result += prefix + line.text + "\n"
                if !line.hasTrailingNewline { result += "\\ No newline at end of file\n" }
            }
        }
        return result
    }

    public static func stats(_ lines: [Line]) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for line in lines {
            if line.kind == .added { added += 1 }
            if line.kind == .removed { removed += 1 }
        }
        return (added, removed)
    }
}

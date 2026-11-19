import Foundation

public enum TokenKind: String, CaseIterable, Sendable, Codable {
    case keyword, string, comment, number, type, function, attribute
}

public struct Token: Sendable, Equatable {
    public var range: NSRange
    public var kind: TokenKind
}

/// Regex-based tokenizer. Later tokens win when ranges overlap, so the result can be applied in order.
///
/// Strings and comments are found by a single alternation regex scanned left to right, which keeps
/// `"// not a comment"` a string and `# "not a string"` a comment.
public enum SyntaxHighlighter {
    private final class Compiled: @unchecked Sendable {
        let base: [(NSRegularExpression, TokenKind, Int)]   // regex, kind, capture group
        let stringsAndComments: NSRegularExpression?
        let commentGroupCount: Int
        let late: [(NSRegularExpression, TokenKind)]

        init(_ spec: LanguageSpec) {
            base = Self.baseRules(spec)
            let comments = Self.commentPatterns(spec)
            let strings = Self.stringPatterns(spec)
            var parts: [String] = []
            if !comments.isEmpty { parts.append("(" + comments.joined(separator: "|") + ")") }
            if !strings.isEmpty { parts.append("(" + strings.joined(separator: "|") + ")") }
            commentGroupCount = comments.isEmpty ? 0 : 1
            stringsAndComments = parts.isEmpty ? nil : try? NSRegularExpression(pattern: parts.joined(separator: "|"), options: [.anchorsMatchLines])
            late = spec.extraRules.filter(\.afterStrings).compactMap { r in
                (try? NSRegularExpression(pattern: r.pattern, options: [.anchorsMatchLines])).map { ($0, r.kind) }
            }
        }

        private typealias Rule = (pattern: String, kind: TokenKind, group: Int, options: NSRegularExpression.Options)

        private static func baseRules(_ spec: LanguageSpec) -> [(NSRegularExpression, TokenKind, Int)] {
            let languageRules = spec.id == "plain" || spec.id == "markdown" ? [] : codeRules(spec)
            let extra: [Rule] = spec.extraRules.filter { !$0.afterStrings }.map { ($0.pattern, $0.kind, 0, []) }
            return (languageRules + extra).compactMap { rule in
                (try? NSRegularExpression(pattern: rule.pattern, options: rule.options.union(.anchorsMatchLines))).map { ($0, rule.kind, rule.group) }
            }
        }

        /// The order matters: later rules win over earlier ones when ranges overlap.
        private static func codeRules(_ spec: LanguageSpec) -> [Rule] {
            var rules: [Rule] = [(#"\b([A-Za-z_][A-Za-z0-9_]*)(?=\s*\()"#, .function, 1, [])]
            if spec.capitalizedAreTypes { rules.append((#"\b[A-Z][A-Za-z0-9_]*\b"#, .type, 0, [])) }
            if !spec.builtins.isEmpty {
                rules.append((#"\b(?:"# + spec.builtins.map(NSRegularExpression.escapedPattern).joined(separator: "|") + #")\b"#, .type, 0, []))
            }
            rules.append((#"(?<![\w.])(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#, .number, 0, []))
            if let prefix = spec.attributePrefix {
                rules.append((NSRegularExpression.escapedPattern(for: prefix) + #"[A-Za-z_{][\w}]*"#, .attribute, 0, []))
            }
            if !spec.keywords.isEmpty {
                let alternatives = spec.keywords.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern)
                rules.append((#"(?<![\w$@])(?:"# + alternatives.joined(separator: "|") + #")(?![\w?])"#, .keyword, 0, spec.caseInsensitive ? [.caseInsensitive] : []))
            }
            return rules
        }

        private static func commentPatterns(_ spec: LanguageSpec) -> [String] {
            var comments = spec.lineComments.map { NSRegularExpression.escapedPattern(for: $0) + ".*$" }
            if let bc = spec.blockComment, bc.count == 2 {
                comments.append(NSRegularExpression.escapedPattern(for: bc[0]) + #"[\s\S]*?(?:"# + NSRegularExpression.escapedPattern(for: bc[1]) + "|$(?![\\s\\S]))")
            }
            return comments
        }

        private static func stringPatterns(_ spec: LanguageSpec) -> [String] {
            spec.stringDelimiters.map { d in
                let e = NSRegularExpression.escapedPattern(for: d)
                if d.count >= 3 || d == "`" { return e + #"[\s\S]*?(?:"# + e + "|$(?![\\s\\S]))" }
                return e + #"(?:\\.|(?!"# + e + #")[^\\\n])*"# + e + "?"
            }
        }
    }

    nonisolated(unsafe) private static var cache: [String: Compiled] = [:]
    private static let lock = NSLock()

    private static func compiled(for spec: LanguageSpec) -> Compiled {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[spec.id] { return c }
        let c = Compiled(spec)
        cache[spec.id] = c
        return c
    }

    public static func tokens(in code: String, language: LanguageSpec) -> [Token] {
        let c = compiled(for: language)
        let full = NSRange(location: 0, length: (code as NSString).length)
        var result: [Token] = c.base.flatMap { tokens($0.0, kind: $0.1, group: $0.2, in: code, range: full) }
        if let sc = c.stringsAndComments {
            result += sc.matches(in: code, range: full).filter { $0.range.length > 0 }.map { m in
                let isComment = c.commentGroupCount == 1 && m.range(at: 1).location != NSNotFound
                return Token(range: m.range, kind: isComment ? .comment : .string)
            }
        }
        return result + c.late.flatMap { tokens($0.0, kind: $0.1, group: 0, in: code, range: full) }
    }

    private static func tokens(_ regex: NSRegularExpression, kind: TokenKind, group: Int, in code: String, range: NSRange) -> [Token] {
        regex.matches(in: code, range: range).compactMap { m in
            let r = m.range(at: group)
            return r.location != NSNotFound && r.length > 0 ? Token(range: r, kind: kind) : nil
        }
    }
}

/// Which part of a code block has to be coloured again after an edit (#221). Recolouring the whole block on every key
/// made AppKit lay out every line again (55 ms per key at 3,000 lines).
public enum HighlightDiff {
    /// The changed text plus every token that appeared, vanished or changed, in the new text's coordinates; nil when
    /// nothing has to be recoloured.
    public static func span(oldText: NSString, newText: NSString, oldTokens: [Token], newTokens: [Token]) -> NSRange? {
        let oldLen = oldText.length, newLen = newText.length
        var prefix = 0
        let limit = min(oldLen, newLen)
        while prefix < limit, oldText.character(at: prefix) == newText.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, oldText.character(at: oldLen - 1 - suffix) == newText.character(at: newLen - 1 - suffix) { suffix += 1 }
        let delta = newLen - oldLen
        var lower = prefix, upper = newLen - suffix
        let changedText = lower < upper || oldLen != newLen
        // Old tokens moved into new coordinates; tokens that touched the edit are dropped (they count as changed).
        var moved = Set<TokenKey>()
        for t in oldTokens {
            if NSMaxRange(t.range) <= prefix { moved.insert(TokenKey(t.range, t.kind)) }
            else if t.range.location >= oldLen - suffix { moved.insert(TokenKey(NSRange(location: t.range.location + delta, length: t.range.length), t.kind)) }
            else { lower = min(lower, t.range.location); upper = max(upper, min(NSMaxRange(t.range) + max(delta, 0), newLen)) }
        }
        let fresh = Set(newTokens.map { TokenKey($0.range, $0.kind) })
        for k in fresh.symmetricDifference(moved) {
            lower = min(lower, k.location)
            upper = max(upper, min(k.location + k.length, newLen))
        }
        guard changedText || lower < upper else { return nil }
        lower = max(0, min(lower, newLen))
        upper = max(lower, min(upper, newLen))
        return NSRange(location: lower, length: upper - lower)
    }

    private struct TokenKey: Hashable {
        var location: Int, length: Int, kind: TokenKind
        init(_ r: NSRange, _ kind: TokenKind) { location = r.location; length = r.length; self.kind = kind }
    }
}

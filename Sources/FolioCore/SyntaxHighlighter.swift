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

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
            var base: [(NSRegularExpression, TokenKind, Int)] = []
            func add(_ p: String, _ k: TokenKind, group: Int = 0, options: NSRegularExpression.Options = []) {
                if let r = try? NSRegularExpression(pattern: p, options: options.union(.anchorsMatchLines)) { base.append((r, k, group)) }
            }
            if spec.id != "plain" && spec.id != "markdown" {
                add(#"\b([A-Za-z_][A-Za-z0-9_]*)(?=\s*\()"#, .function, group: 1)
                if spec.capitalizedAreTypes { add(#"\b[A-Z][A-Za-z0-9_]*\b"#, .type) }
                if !spec.builtins.isEmpty {
                    add(#"\b(?:"# + spec.builtins.map(NSRegularExpression.escapedPattern).joined(separator: "|") + #")\b"#, .type)
                }
                add(#"(?<![\w.])(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#, .number)
                if let prefix = spec.attributePrefix {
                    add(NSRegularExpression.escapedPattern(for: prefix) + #"[A-Za-z_{][\w}]*"#, .attribute)
                }
                if !spec.keywords.isEmpty {
                    let alternatives = spec.keywords.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern)
                    add(#"(?<![\w$@])(?:"# + alternatives.joined(separator: "|") + #")(?![\w?])"#, .keyword,
                        options: spec.caseInsensitive ? [.caseInsensitive] : [])
                }
            }
            for rule in spec.extraRules where !rule.afterStrings { add(rule.pattern, rule.kind) }
            self.base = base

            var comments: [String] = []
            for marker in spec.lineComments { comments.append(NSRegularExpression.escapedPattern(for: marker) + ".*$") }
            if let bc = spec.blockComment, bc.count == 2 {
                comments.append(NSRegularExpression.escapedPattern(for: bc[0]) + #"[\s\S]*?(?:"# + NSRegularExpression.escapedPattern(for: bc[1]) + "|$(?![\\s\\S]))")
            }
            var strings: [String] = []
            for d in spec.stringDelimiters {
                let e = NSRegularExpression.escapedPattern(for: d)
                if d.count >= 3 || d == "`" {
                    strings.append(e + #"[\s\S]*?(?:"# + e + "|$(?![\\s\\S]))")
                } else {
                    strings.append(e + #"(?:\\.|(?!"# + e + #")[^\\\n])*"# + e + "?")
                }
            }
            var parts: [String] = []
            if !comments.isEmpty { parts.append("(" + comments.joined(separator: "|") + ")") }
            if !strings.isEmpty { parts.append("(" + strings.joined(separator: "|") + ")") }
            commentGroupCount = comments.isEmpty ? 0 : 1
            stringsAndComments = parts.isEmpty ? nil : try? NSRegularExpression(pattern: parts.joined(separator: "|"), options: [.anchorsMatchLines])
            late = spec.extraRules.filter(\.afterStrings).compactMap { r in
                (try? NSRegularExpression(pattern: r.pattern, options: [.anchorsMatchLines])).map { ($0, r.kind) }
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
        var result: [Token] = []
        for (regex, kind, group) in c.base {
            for m in regex.matches(in: code, range: full) {
                let r = m.range(at: group)
                if r.location != NSNotFound && r.length > 0 { result.append(Token(range: r, kind: kind)) }
            }
        }
        if let sc = c.stringsAndComments {
            for m in sc.matches(in: code, range: full) where m.range.length > 0 {
                let isComment = c.commentGroupCount == 1 && m.range(at: 1).location != NSNotFound
                result.append(Token(range: m.range, kind: isComment ? .comment : .string))
            }
        }
        for (regex, kind) in c.late {
            for m in regex.matches(in: code, range: full) where m.range.length > 0 {
                result.append(Token(range: m.range, kind: kind))
            }
        }
        return result
    }
}

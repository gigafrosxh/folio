import Foundation

public enum CompletionKind: String, Sendable, Hashable {
    case method, function, property, field, variable, `class`, interface, module, keyword, constant, snippet, other
}

/// One entry of the completion list.
public struct CompletionItem: Sendable, Hashable {
    public var label: String
    public var kind: CompletionKind
    /// Signature or type shown next to the label, e.g. "PrintStream" or "(String) -> void".
    public var detail: String?
    /// Text that replaces the typed prefix when the item is accepted.
    public var insertText: String

    public init(label: String, kind: CompletionKind, detail: String? = nil, insertText: String? = nil) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.insertText = insertText ?? label
    }
}

/// Where the cursor is: `System.ou|` → receiver "System", prefix "ou".
public struct CompletionContext: Sendable, Equatable {
    public var code: String
    /// Cursor position in UTF-16 units.
    public var offset: Int
    public var language: String
    /// Expression before the last `.` (or `::`/`->`), nil when completing a bare identifier.
    public var receiver: String?
    /// Identifier characters typed right before the cursor.
    public var prefix: String
    /// Zero-based line and UTF-16 column of the cursor (LSP positions).
    public var line: Int
    public var column: Int

    public init(code: String, offset: Int, language: String) {
        self.code = code
        self.language = language
        let ns = code as NSString
        let off = min(max(offset, 0), ns.length)
        self.offset = off
        func isIdent(_ c: unichar) -> Bool {
            guard let s = Unicode.Scalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(s) || c == 95 || c == 36 // _ $
        }
        var start = off
        while start > 0, isIdent(ns.character(at: start - 1)) { start -= 1 }
        prefix = ns.substring(with: NSRange(location: start, length: off - start))

        // Receiver: a dotted chain of identifiers, calls or indexes before a member access.
        var r: String?
        var i = start
        var sepLength = 0
        if i >= 1, ns.character(at: i - 1) == 46 { sepLength = 1 }                                   // .
        else if i >= 2, ns.substring(with: NSRange(location: i - 2, length: 2)) == "::" { sepLength = 2 }
        else if i >= 2, ns.substring(with: NSRange(location: i - 2, length: 2)) == "->" { sepLength = 2 }
        if sepLength > 0 {
            i -= sepLength
            var j = i
            var depth = 0
            scan: while j > 0 {
                let c = ns.character(at: j - 1)
                switch c {
                case 41, 93: depth += 1                         // ) ]
                case 40, 91:                                    // ( [
                    if depth == 0 { break scan }
                    depth -= 1
                case 46: break                                  // .
                case 58 where j >= 2 && ns.character(at: j - 2) == 58: j -= 1   // ::
                default:
                    if depth == 0 && !isIdent(c) { break scan }
                }
                j -= 1
            }
            let expr = ns.substring(with: NSRange(location: j, length: i - j)).trimmingCharacters(in: .whitespaces)
            if !expr.isEmpty { r = expr }
        }
        receiver = r

        let before = ns.substring(to: off)
        let lines = before.components(separatedBy: "\n")
        line = lines.count - 1
        column = ((lines.last ?? "") as NSString).length
    }
}

/// A source of completions for some languages.
public protocol CompletionProvider: Sendable {
    func supports(_ language: String) -> Bool
    func complete(_ context: CompletionContext) async -> [CompletionItem]
}

/// Words that are always offered: language keywords, builtins and identifiers already used in the code.
public enum WordCompleter {
    public static func complete(_ ctx: CompletionContext) -> [CompletionItem] {
        guard ctx.receiver == nil, !ctx.prefix.isEmpty else { return [] }
        let spec = Languages.spec(for: ctx.language)
        var seen = Set<String>()
        var items: [CompletionItem] = []
        for k in spec.keywords.sorted() where seen.insert(k).inserted { items.append(CompletionItem(label: k, kind: .keyword)) }
        for b in spec.builtins.sorted() where seen.insert(b).inserted { items.append(CompletionItem(label: b, kind: .function)) }
        let regex = try! NSRegularExpression(pattern: #"[A-Za-z_$][A-Za-z0-9_$]{2,}"#)
        let ns = ctx.code as NSString
        for m in regex.matches(in: ctx.code, range: NSRange(location: 0, length: ns.length)) {
            // Skip the word being typed itself.
            if NSMaxRange(m.range) == ctx.offset { continue }
            let w = ns.substring(with: m.range)
            if seen.insert(w).inserted { items.append(CompletionItem(label: w, kind: .variable)) }
        }
        return CompletionFilter.filter(items, prefix: ctx.prefix)
    }
}

public enum CompletionFilter {
    /// Prefix matches first (case-sensitive before case-insensitive), then substring matches; drops exact
    /// matches of what is already typed.
    public static func filter(_ items: [CompletionItem], prefix: String, limit: Int = 200) -> [CompletionItem] {
        guard !prefix.isEmpty else { return Array(dedupe(items).prefix(limit)) }
        let lower = prefix.lowercased()
        func rank(_ item: CompletionItem) -> Int? {
            let l = item.label
            if l == prefix { return nil }
            if l.hasPrefix(prefix) { return 0 }
            if l.lowercased().hasPrefix(lower) { return 1 }
            if l.lowercased().contains(lower) { return 2 }
            return nil
        }
        let ranked = dedupe(items).compactMap { item in rank(item).map { (item, $0) } }
        return ranked.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            return a.0.label.count < b.0.label.count
        }.prefix(limit).map(\.0)
    }

    static func dedupe(_ items: [CompletionItem]) -> [CompletionItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.label).inserted }
    }
}

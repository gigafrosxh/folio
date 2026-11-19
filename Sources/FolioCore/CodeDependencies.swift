import Foundation

/// When and with which code a block last ran (#26). Saved with the block, so "veraltet" survives a restart.
public struct CodeRunStamp: Codable, Sendable, Equatable {
    public struct Upstream: Codable, Sendable, Equatable {
        public var block: UUID
        public var names: [String]
        public var ranAt: Date?
    }

    public var ranAt: Date
    /// Includes execution inputs for new stamps. Older stamps contain only the code hash.
    public var codeHash: String
    /// Nil for legacy stamps. An empty array records a run without dependencies.
    public var upstream: [Upstream]?
    public var succeeded: Bool

    public init(ranAt: Date = Date(), codeHash: String, succeeded: Bool, upstream: [Upstream]? = nil) {
        self.upstream = upstream
        self.ranAt = ranAt
        self.codeHash = codeHash
        self.succeeded = succeeded
    }
}

/// Which code blocks of a note build on which, in what order they have to run, and whose results are out of date (#26).
///
/// Blocks of one shared session (same language, not isolated) see each other's variables. A block depends on the
/// nearest earlier block of its session that defines a name it uses. The names come from a light, per-language scan
/// (definitions, imports, assignments); it is a guide for the reader, not a compiler.
public enum CodeDependencies {
    public struct Item: Sendable, Equatable {
        public var id: UUID
        public var language: String
        /// Session key (usually the language); nil for blocks that run on their own.
        public var session: String?
        public var code: String
        public var lastRun: CodeRunStamp?
        public var stdin: String?
        public var interactive: Bool
        public var isolated: Bool
        public var running: Bool

        public init(
            id: UUID, language: String, session: String?, code: String, lastRun: CodeRunStamp?, running: Bool = false,
            stdin: String? = nil, interactive: Bool = false, isolated: Bool = false
        ) {
            self.id = id
            self.language = language
            self.session = session
            self.code = code
            self.lastRun = lastRun
            self.stdin = stdin
            self.interactive = interactive
            self.isolated = isolated
            self.running = running
        }

        public var fingerprint: String {
            // Length prefixes preserve arbitrary stdin, including trailing whitespace and delimiters.
            let fields = [CodeDependencies.fingerprint(code), language, stdin ?? "", String(interactive), String(isolated)]
            return CodeDependencies.hash(fields.map { "\($0.utf8.count):\($0)" }.joined())
        }
    }

    public struct Edge: Sendable, Equatable, Hashable {
        /// The block that defines the names.
        public var from: UUID
        /// The block that uses them.
        public var to: UUID
        public var names: [String]

        fileprivate func snapshot(source: Item?) -> CodeRunStamp.Upstream {
            CodeRunStamp.Upstream(block: from, names: names, ranAt: source?.lastRun?.ranAt)
        }
    }

    public enum Status: Sendable, Equatable {
        case notRun
        case running
        case ok
        case failed
        /// Ran, but its result may no longer match: the code changed or something it builds on is newer or missing.
        case stale(String)

        public var isStale: Bool { if case .stale = self { return true } else { return false } }
        public var label: String {
            switch self {
            case .notRun: return "nicht ausgeführt"
            case .running: return "läuft"
            case .ok: return "aktuell"
            case .failed: return "Fehler"
            case .stale: return "veraltet"
            }
        }
    }

    /// A name a block uses that only a later block of its session defines: running top to bottom fails.
    public struct OrderWarning: Sendable, Equatable {
        public var block: UUID
        public var name: String
        public var definedIn: UUID
    }

    public struct Graph: Sendable, Equatable {
        public var items: [Item]
        public var edges: [Edge]
        public var status: [UUID: Status]
        public var warnings: [OrderWarning]

        public func upstream(of id: UUID) -> [Edge] { edges.filter { $0.to == id } }
        public func downstream(of id: UUID) -> [Edge] { edges.filter { $0.from == id } }
        public func runStamp(for item: Item, succeeded: Bool) -> CodeRunStamp {
            let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let upstream = upstream(of: item.id).map { $0.snapshot(source: byID[$0.from]) }
            return CodeRunStamp(codeHash: item.fingerprint, succeeded: succeeded, upstream: upstream)
        }

        /// Blocks to run again, in note order, so that every result is up to date.
        public var staleInOrder: [UUID] { items.map(\.id).filter { status[$0]?.isStale == true } }
        /// Number (1-based, in note order) of a block, for labels like "Block 2".
        public func number(of id: UUID) -> Int? { items.firstIndex { $0.id == id }.map { $0 + 1 } }
    }

    public static func build(_ items: [Item]) -> Graph {
        let symbols = items.map { SymbolScan.cachedScan($0.code, language: $0.language) }
        var edges: [Edge] = []
        var warnings: [OrderWarning] = []
        for i in items.indices where items[i].session != nil {
            let (incoming, missing) = links(into: i, items: items, symbols: symbols)
            edges += incoming
            warnings += missing
        }
        return Graph(items: items, edges: edges, status: status(items, edges: edges), warnings: warnings)
    }

    /// Edges into block `i` (grouped by defining block) and names only a later block defines.
    private static func links(into i: Int, items: [Item], symbols: [SymbolScan.Symbols]) -> ([Edge], [OrderWarning]) {
        let session = items[i].session
        let definer = { (range: [Int], name: String) in range.filter { items[$0].session == session && symbols[$0].defines.contains(name) } }
        var edges: [Edge] = []
        var warnings: [OrderWarning] = []
        for name in symbols[i].uses.sorted() {
            if let j = definer(Array(0..<i), name).last {
                if let k = edges.firstIndex(where: { $0.from == items[j].id }) {
                    edges[k].names.append(name)
                } else {
                    edges.append(Edge(from: items[j].id, to: items[i].id, names: [name]))
                }
            } else if !symbols[i].defines.contains(name), let k = definer(Array((i + 1)..<items.count), name).first {
                warnings.append(OrderWarning(block: items[i].id, name: name, definedIn: items[k].id))
            }
        }
        return (edges, warnings)
    }

    private static func status(_ items: [Item], edges: [Edge]) -> [UUID: Status] {
        var result: [UUID: Status] = [:]
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let number = Dictionary(items.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        let incoming = Dictionary(grouping: edges, by: \.to)
        // Edges always point downwards, so one pass in note order sees every predecessor first.
        for item in items {
            result[item.id] = ownStatus(item) ?? upstreamStatus(item, incoming: incoming[item.id] ?? [], byID: byID, number: number, known: result)
        }
        return result
    }

    /// Status that follows from the block alone; nil when its predecessors decide.
    private static func ownStatus(_ item: Item) -> Status? {
        if item.running { return .running }
        guard let run = item.lastRun else { return .notRun }
        if run.upstream == nil {
            return run.succeeded ? .stale("Abhängigkeiten der letzten Ausführung unbekannt") : .failed
        }
        if run.codeHash != item.fingerprint { return .stale("Code oder Ausführungseinstellungen geändert") }
        return nil
    }

    private static func upstreamStatus(_ item: Item, incoming: [Edge], byID: [UUID: Item], number: [UUID: Int], known: [UUID: Status]) -> Status {
        guard let run = item.lastRun else { return .notRun }
        let current = incoming.map { $0.snapshot(source: byID[$0.from]) }
        if run.upstream != current { return .stale("Abhängigkeiten seit der letzten Ausführung geändert") }
        for edge in incoming {
            if let reason = staleReason(source: byID[edge.from], status: known[edge.from], label: "Block \(number[edge.from] ?? 0)", ranAt: run.ranAt) {
                return .stale(reason)
            }
        }
        return run.succeeded ? .ok : .failed
    }

    private static func staleReason(source: Item?, status: Status?, label: String, ranAt: Date) -> String? {
        switch status {
        case .notRun?: return "\(label) wurde nicht ausgeführt"
        case .stale?: return "\(label) ist veraltet"
        case .failed?: return "\(label) ist fehlgeschlagen"
        default:
            guard let sourceRun = source?.lastRun, sourceRun.ranAt > ranAt else { return nil }
            return "\(label) wurde danach neu ausgeführt"
        }
    }

    /// A short, stable fingerprint of a block's code (FNV-1a, 64 bit). Line endings and trailing spaces at the end do not count.
    public static func fingerprint(_ code: String) -> String {
        var normalized = code.replacingOccurrences(of: "\r\n", with: "\n")
        while let last = normalized.last, last.isWhitespace { normalized.removeLast() }
        return hash(normalized)
    }

    fileprivate static func hash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// Names a piece of code defines and uses, found with a few patterns per language.
public enum SymbolScan {
    public struct Symbols: Sendable, Equatable {
        public var defines: Set<String>
        public var uses: Set<String>
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Symbols] = [:]

    /// Reuse symbol scans for unchanged blocks across graph revisions.
    public static func cachedScan(_ code: String, language: String) -> Symbols {
        let key = language + "\u{1}" + CodeDependencies.fingerprint(code) + "\u{1}\(code.utf8.count)"
        cacheLock.lock()
        if let hit = cache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()
        let symbols = scan(code, language: language)
        cacheLock.lock()
        if cache.count > 2_000 { cache.removeAll() }
        cache[key] = symbols
        cacheLock.unlock()
        return symbols
    }

    public static func scan(_ code: String, language: String) -> Symbols {
        let lang = language.lowercased()
        let source = stripCommentsAndStrings(code, language: lang) as NSString
        let (defines, definitionRanges) = definitions(in: source, language: lang)
        return Symbols(defines: defines, uses: uses(in: source, language: lang, skipping: definitionRanges))
    }

    private static func matches(_ pattern: String, in s: NSString) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        return regex.matches(in: s as String, range: NSRange(location: 0, length: s.length))
    }

    private static func definitions(in source: NSString, language lang: String) -> (Set<String>, [NSRange]) {
        var defines = Set<String>()
        var ranges: [NSRange] = []
        for pattern in definitionPatterns(lang) {
            for match in matches(pattern, in: source) where match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound {
                // A group may hold several names: "a, b = …", "import x, y", "from m import a as b, c".
                defines.formUnion(names(inDefinitionList: source.substring(with: match.range(at: 1))))
                ranges.append(match.range(at: 1))
            }
        }
        return (defines, ranges)
    }

    private static func uses(in source: NSString, language lang: String, skipping definitionRanges: [NSRange]) -> Set<String> {
        // `x += 1` both reads and writes x.
        var uses = Set(
            matches(#"^[ \t]*([A-Za-z_$][\w$]*)[ \t]*(?:\+|-|\*|/|%|\|\||&&|\?\?|\||<<|>>)=(?!=)"#, in: source)
                .map { source.substring(with: $0.range(at: 1)) })
        let keywords = Self.keywords(lang)
        for match in matches("(?<![\\w.$@])[A-Za-z_$][\\w$]*", in: source) {
            let r = match.range
            let name = source.substring(with: r)
            guard !keywords.contains(name), !definitionRanges.contains(where: { NSLocationInRange(r.location, $0) }),
                !isKeywordArgument(source, range: r)
            else { continue }
            uses.insert(name)
        }
        return uses
    }

    /// Keyword arguments (`f(x=1)`) name a parameter, not a variable.
    private static func isKeywordArgument(_ s: NSString, range r: NSRange) -> Bool {
        let after = r.location + r.length
        guard after < s.length else { return false }
        let rest = s.substring(from: after).prefix(3)
        return rest.hasPrefix("=") && !rest.hasPrefix("==") && isInsideCall(s, at: r.location)
    }

    private static func names(inDefinitionList group: String) -> [String] {
        group.components(separatedBy: CharacterSet(charactersIn: ",()[]{}*"))
            .map { part -> String in
                // "a as b" binds b; "x: int" binds x.
                let words = part.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if let asIndex = words.firstIndex(of: "as"), asIndex + 1 < words.count { return words[asIndex + 1] }
                return (words.first ?? "").components(separatedBy: ":").first ?? ""
            }
            .map { $0.components(separatedBy: ".").first ?? $0 }
            .filter { !$0.isEmpty && $0.range(of: "^[A-Za-z_$][\\w$]*$", options: .regularExpression) != nil }
    }

    private static func isInsideCall(_ s: NSString, at location: Int) -> Bool {
        var depth = 0
        var i = location - 1
        while i >= 0 {
            let c = s.character(at: i)
            if c == 0x29 {
                depth += 1
            }  // )
            else if c == 0x28 {  // (
                if depth == 0 { return true }
                depth -= 1
            } else if c == 0x0A && depth == 0 {
                return false
            }
            i -= 1
        }
        return false
    }

    static func definitionPatterns(_ lang: String) -> [String] {
        let assign = #"^[ \t]*([A-Za-z_$][\w$]*(?:[ \t]*,[ \t]*[A-Za-z_$][\w$]*)*)[ \t]*(?::[^=\n]+)?(?:\+|-|\*|/|%|\|\||&&|\?\?|\|)?=(?!=)"#
        switch lang {
        case "python":
            return [
                assign,
                #"^[ \t]*(?:async[ \t]+)?(?:def|class)[ \t]+([A-Za-z_]\w*)"#,
                #"^[ \t]*import[ \t]+([\w., \t]+(?:[ \t]+as[ \t]+\w+)?)"#,
                #"^[ \t]*from[ \t]+[\w.]+[ \t]+import[ \t]+\(?([\w, \t]+(?:as[ \t]+\w+)?[\w, \t]*)"#,
                #"^[ \t]*for[ \t]+([\w, \t()]+?)[ \t]+in[ \t]"#,
                #"\bas[ \t]+([A-Za-z_]\w*)[ \t]*:"#,
                #"^[ \t]*global[ \t]+([\w, \t]+)"#
            ]
        case "javascript", "typescript", "node":
            return [
                #"\b(?:let|const|var)[ \t]+([A-Za-z_$][\w$]*)"#,
                #"\b(?:let|const|var)[ \t]+[\[{]([^\]}=]+)[\]}]"#,
                #"\b(?:async[ \t]+)?function\*?[ \t]+([A-Za-z_$][\w$]*)"#,
                #"\bclass[ \t]+([A-Za-z_$][\w$]*)"#,
                #"\bimport[ \t]+([A-Za-z_$][\w$]*)[ \t]+from"#,
                #"\bimport[ \t]*\{([^}]*)\}"#,
                #"\bimport[ \t]*\*[ \t]*as[ \t]+([A-Za-z_$][\w$]*)"#,
                assign
            ]
        case "r":
            return [#"^[ \t]*([A-Za-z_.][\w.]*)[ \t]*(?:<<?-|=(?!=))"#, #"^[ \t]*library\(([\w.]+)\)"#]
        case "julia":
            return [
                assign, #"^[ \t]*(?:function|struct|mutable struct|macro|module)[ \t]+([A-Za-z_]\w*)"#,
                #"^[ \t]*(?:using|import)[ \t]+([\w., \t]+)"#
            ]
        case "ruby":
            return [assign, #"^[ \t]*(?:def|class|module)[ \t]+(?:self\.)?([A-Za-z_]\w*)"#]
        case "swift":
            return [#"\b(?:let|var|func|class|struct|enum|actor|protocol|typealias)[ \t]+([A-Za-z_]\w*)"#, #"^[ \t]*import[ \t]+(\w+)"#]
        case "bash", "zsh", "sh", "fish":
            return [#"^[ \t]*(?:export[ \t]+|local[ \t]+)?([A-Za-z_]\w*)=(?!=)"#, #"^[ \t]*(?:function[ \t]+)?([A-Za-z_]\w*)[ \t]*\(\)"#]
        default:
            return [assign, #"\b(?:def|function|func|fn|class|struct|let|const|var|val)[ \t]+([A-Za-z_$][\w$]*)"#]
        }
    }

    /// Replaces comments and string contents with spaces (keeping offsets and line breaks), so names inside them do not count.
    static func stripCommentsAndStrings(_ code: String, language lang: String) -> String {
        var scanner = Stripper(chars: Array(code), hashComments: ["python", "r", "ruby", "julia", "bash", "zsh", "sh", "fish", "perl"].contains(lang))
        return scanner.run()
    }

    private struct Stripper {
        let chars: [Character]
        let hashComments: Bool
        var out: [Character] = []
        var i = 0

        init(chars: [Character], hashComments: Bool) {
            self.chars = chars
            self.hashComments = hashComments
            out.reserveCapacity(chars.count)
        }

        private func at(_ k: Int) -> Character? { k < chars.count ? chars[k] : nil }
        private static func blank(_ c: Character) -> Character { c == "\n" ? "\n" : " " }

        mutating func run() -> String {
            while i < chars.count {
                let c = chars[i], next = at(i + 1)
                if (hashComments && c == "#") || (!hashComments && c == "/" && next == "/") {
                    lineComment()
                } else if !hashComments && c == "/" && next == "*" {
                    blockComment()
                } else if c == "\"" || c == "'" || c == "`" {
                    string(c)
                } else {
                    out.append(c)
                    i += 1
                }
            }
            return String(out)
        }

        private mutating func lineComment() {
            while i < chars.count && chars[i] != "\n" {
                out.append(" ")
                i += 1
            }
        }

        private mutating func blockComment() {
            while i < chars.count && !(chars[i] == "*" && at(i + 1) == "/") {
                out.append(Self.blank(chars[i]))
                i += 1
            }
            if i < chars.count {
                out.append(contentsOf: "  ")
                i += 2
            }
        }

        private func closes(_ quote: Character, triple: Bool) -> Bool {
            triple ? chars[i] == quote && at(i + 1) == quote && at(i + 2) == quote : chars[i] == quote
        }

        private mutating func string(_ quote: Character) {
            let triple = at(i + 1) == quote && at(i + 2) == quote  // Python triple quotes
            let length = triple ? 3 : 1
            out.append(contentsOf: Array(repeating: quote, count: length))
            i += length
            while i < chars.count && !closes(quote, triple: triple) && (triple || quote == "`" || chars[i] != "\n") {
                if chars[i] == "\\" {
                    out.append(" ")
                    if let n = at(i + 1) { out.append(Self.blank(n)) }
                    i += 2
                } else {
                    out.append(Self.blank(chars[i]))
                    i += 1
                }
            }
            guard i < chars.count, chars[i] != "\n" else { return }
            out.append(contentsOf: Array(repeating: quote, count: length))
            i += length
        }
    }

    static func keywords(_ lang: String) -> Set<String> {
        var common: Set<String> = [
            "if", "else", "for", "while", "return", "in", "and", "or", "not", "is", "true", "false",
            "True", "False", "None", "null", "nil", "undefined", "def", "class", "import", "from", "as",
            "let", "const", "var", "function", "new", "this", "self", "try", "catch", "except", "finally",
            "with", "lambda", "yield", "await", "async", "break", "continue", "pass", "raise", "throw",
            "elif", "do", "end", "then", "fi", "done", "case", "switch", "default", "typeof", "instanceof",
            "global", "nonlocal", "del", "assert", "of", "func", "struct", "enum", "export", "local", "echo",
            "print", "len", "range", "str", "int", "float", "list", "dict", "set", "tuple", "type", "console",
            "Math", "JSON", "Object", "Array", "String", "Number", "require", "module", "library", "c"
        ]
        if lang == "python" { common.formUnion(["open", "sorted", "sum", "min", "max", "abs", "enumerate", "zip", "map", "filter", "isinstance", "super", "object", "bool"]) }
        return common
    }
}

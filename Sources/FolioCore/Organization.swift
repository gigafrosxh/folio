import Foundation

// MARK: - Note links (#7)

/// Links between notes use the note's stable id: `folio://note/<UUID>`. Titles and file names may
/// change, the link keeps working.
public enum NoteLink {
    public static let scheme = "folio"

    public static func url(for id: UUID) -> URL { URL(string: "\(scheme)://note/\(id.uuidString)")! }

    public static func id(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == scheme, url.host()?.lowercased() == "note" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    /// Ids of notes that link to `id`.
    public static func backlinks(to id: UUID, in notes: [NoteMetadata]) -> [NoteMetadata] {
        notes.filter { $0.id != id && $0.links.contains(id) }
    }
}

// MARK: - Fuzzy matching (#20)

public enum FuzzyMatch {
    /// Score of `query` against `text` (higher is better), nil when not all query characters appear in order.
    /// Rewards consecutive characters, matches at word starts and a match at the very beginning.
    public static func score(_ query: String, in text: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let t = Array(text.lowercased())
        // Two passes: plain left-to-right, and one that prefers word starts ("pn" → Python Notizen).
        let best = [pass(q, t, preferWordStarts: false), pass(q, t, preferWordStarts: true)].compactMap { $0 }.max()
        // Shorter texts with the same matches rank first.
        return best.map { $0 * 10 - min(t.count, 200) / 10 }
    }

    private static func isWordStart(_ t: [Character], _ i: Int) -> Bool {
        i == 0 || (!t[i - 1].isLetter && !t[i - 1].isNumber)
    }

    private static func pass(_ q: [Character], _ t: [Character], preferWordStarts: Bool) -> Int? {
        var score = 0, last = -2, pos = 0
        for c in q {
            var found: Int?
            if preferWordStarts {
                found = (pos..<t.count).first { t[$0] == c && isWordStart(t, $0) }
            }
            if found == nil { found = (pos..<t.count).first { t[$0] == c } }
            guard let i = found else { return nil }
            var s = 1
            if i == last + 1 { s += 5 }
            if i == 0 { s += 8 } else if isWordStart(t, i) { s += 4 }
            score += s
            last = i
            pos = i + 1
        }
        return score
    }

    /// Items sorted by score, unmatched ones removed; ties keep their original order.
    public static func rank<T>(_ items: [T], query: String, text: (T) -> String) -> [T] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items.enumerated()
            .compactMap { i, item in score(query, in: text(item)).map { (i, item, $0) } }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .map(\.1)
    }
}

/// Recently opened notes, newest first, without duplicates.
public struct RecentList: Codable, Equatable, Sendable {
    public private(set) var ids: [UUID]
    public var limit: Int

    public init(ids: [UUID] = [], limit: Int = 30) {
        self.ids = ids
        self.limit = limit
    }

    public mutating func opened(_ id: UUID) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > limit { ids.removeLast(ids.count - limit) }
    }

    public mutating func remove(_ id: UUID) { ids.removeAll { $0 == id } }
}

// MARK: - Search with filters (#8)

/// A search: free text plus optional filters. Typed filters (`tag:`, `ordner:`, `typ:`, `seit:`) are
/// understood too, so the simple search field keeps working as before.
public struct SearchFilter: Equatable, Sendable {
    public enum Period: String, CaseIterable, Sendable {
        case any, today, week, month, year
        public var label: String {
            switch self {
            case .any: return "Beliebig"
            case .today: return "Heute"
            case .week: return "Letzte 7 Tage"
            case .month: return "Letzte 30 Tage"
            case .year: return "Letztes Jahr"
            }
        }
        func start(now: Date) -> Date? {
            switch self {
            case .any: return nil
            case .today: return Calendar.current.startOfDay(for: now)
            case .week: return now.addingTimeInterval(-7 * 86_400)
            case .month: return now.addingTimeInterval(-30 * 86_400)
            case .year: return now.addingTimeInterval(-365 * 86_400)
            }
        }
    }

    /// Content types users can filter by, with the block kinds behind them.
    public static let contentTypes: [(id: String, label: String, kinds: [String])] = [
        ("code", "Code", ["code"]), ("bild", "Bilder", ["image", "drawing"]), ("pdf", "PDFs", ["pdf"]),
        ("datei", "Dateien & Tabellen", ["file"]), ("web", "Webseiten", ["web"]), ("audio", "Audio", ["audio"]),
        ("formel", "Formeln", ["math"]), ("diagramm", "Diagramme", ["diagram"]), ("datenbank", "Datenbank", ["database"]),
    ]

    public var text = ""
    public var tags: Set<String> = []
    /// Folder paths relative to the library ("Projekte/Alt"); a folder includes its subfolders.
    public var folder: String?
    public var period: Period = .any
    public var types: Set<String> = []

    public init(text: String = "", tags: Set<String> = [], folder: String? = nil, period: Period = .any, types: Set<String> = []) {
        self.text = text
        self.tags = tags
        self.folder = folder
        self.period = period
        self.types = types
    }

    public var hasFilters: Bool { !tags.isEmpty || folder != nil || period != .any || !types.isEmpty }
    public var isEmpty: Bool { !hasFilters && text.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Reads typed filters out of the search text: `tag:rezept`, `#rezept`, `ordner:Projekte`,
    /// `typ:code`, `seit:7` (days) or `seit:heute`. Everything else stays free text.
    public static func parse(_ input: String) -> SearchFilter {
        var f = SearchFilter()
        var words: [String] = []
        for word in input.split(separator: " ").map(String.init) {
            let lower = word.lowercased()
            if lower.hasPrefix("tag:"), lower.count > 4 { f.tags.insert(String(lower.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "#"))) }
            else if lower.hasPrefix("#"), lower.count > 1, lower.dropFirst().first?.isLetter == true { f.tags.insert(String(lower.dropFirst())) }
            else if lower.hasPrefix("ordner:"), word.count > 7 { f.folder = String(word.dropFirst(7)) }
            else if lower.hasPrefix("typ:"), let t = contentTypes.first(where: { $0.id == lower.dropFirst(4) || $0.label.lowercased() == lower.dropFirst(4) }) { f.types.insert(t.id) }
            else if lower.hasPrefix("seit:") {
                let v = lower.dropFirst(5)
                switch v {
                case "heute": f.period = .today
                case "woche", "7": f.period = .week
                case "monat", "30": f.period = .month
                case "jahr", "365": f.period = .year
                default: words.append(word)
                }
            } else { words.append(word) }
        }
        f.text = words.joined(separator: " ")
        return f
    }

    /// Combines typed filters with the ones chosen in the filter menu.
    public func merged(with other: SearchFilter) -> SearchFilter {
        var f = self
        f.text = [text, other.text].filter { !$0.isEmpty }.joined(separator: " ")
        f.tags.formUnion(other.tags)
        f.folder = other.folder ?? folder
        if other.period != .any { f.period = other.period }
        f.types.formUnion(other.types)
        return f
    }

    /// Whether a note matches. `folderPath` is its folder relative to the library; `kinds` its block
    /// kinds when the metadata does not have them.
    public func matches(_ meta: NoteMetadata, folderPath: String, kinds: [String]? = nil, now: Date = Date()) -> Bool {
        if !tags.isEmpty {
            // A tag filter also matches nested tags: "projekt" finds "projekt/alpha".
            let noteTags = meta.tags.map { $0.lowercased() }
            for tag in tags where !noteTags.contains(where: { $0 == tag || $0.hasPrefix(tag + "/") }) { return false }
        }
        if let folder, !folder.isEmpty {
            let f = folder.lowercased(), p = folderPath.lowercased()
            if p != f && !p.hasPrefix(f + "/") { return false }
        }
        if let start = period.start(now: now), meta.modified < start { return false }
        if !types.isEmpty {
            let have = Set(kinds ?? meta.kinds ?? [])
            for t in types {
                guard let def = Self.contentTypes.first(where: { $0.id == t }) else { continue }
                if have.isDisjoint(with: def.kinds) { return false }
            }
        }
        // Every word must appear in title or text (in any order).
        for word in text.lowercased().split(separator: " ") {
            if !meta.title.lowercased().contains(word) && !meta.searchText.lowercased().contains(word) { return false }
        }
        return true
    }
}

// MARK: - Tags (#18)

public enum TagEdit {
    /// Ranges (UTF-16) of `#tag` tokens for `tag` (case-insensitive), including nested children
    /// (`#projekt/alpha` for `projekt`), with the replacement each gets when renaming to `newTag`
    /// (nil = remove the tag).
    public static func edits(in text: String, tag: String, to newTag: String?) -> [(range: NSRange, replacement: String)] {
        let old = tag.lowercased()
        return TagParser.matches(in: text).compactMap { m in
            let t = m.tag.lowercased()
            guard t == old || t.hasPrefix(old + "/") else { return nil }
            guard let newTag else {
                // Remove "#tag" and one following space, so no double spaces stay behind.
                var r = m.range
                let ns = text as NSString
                if NSMaxRange(r) < ns.length, ns.character(at: NSMaxRange(r)) == 32 { r.length += 1 }
                return (r, "")
            }
            return (m.range, "#" + newTag + String(m.tag.dropFirst(old.count)))
        }
    }

    /// Applies the edits to a plain string (for tests and plain-text blocks).
    public static func apply(_ text: String, tag: String, to newTag: String?) -> String {
        let ns = NSMutableString(string: text)
        for e in edits(in: text, tag: tag, to: newTag).reversed() { ns.replaceCharacters(in: e.range, with: e.replacement) }
        return ns as String
    }

    /// A tag name as typed by the user ("#Neu Tag" → "neu-tag"), or nil when unusable.
    public static func normalized(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix("#") { s.removeFirst() }
        s = s.replacingOccurrences(of: " ", with: "-").lowercased()
        guard let first = s.first, first.isLetter else { return nil }
        guard TagParser.tags(in: "#" + s) == [s] else { return nil }
        return s
    }
}

// MARK: - Templates (#6)

public enum TemplateText {
    /// Replaces placeholders in a template: {{datum}}, {{uhrzeit}}, {{wochentag}}, {{kw}} (case-insensitive).
    public static func fill(_ text: String, now: Date = Date(), locale: Locale = Locale(identifier: "de_DE")) -> String {
        guard text.contains("{{") else { return text }
        var out = text
        for (key, value) in values(now: now, locale: locale) {
            out = out.replacingOccurrences(of: "{{\(key)}}", with: value, options: .caseInsensitive)
        }
        return out
    }

    /// Placeholder names (without braces) and their values.
    public static func values(now: Date = Date(), locale: Locale = Locale(identifier: "de_DE")) -> [String: String] {
        let f = DateFormatter()
        f.locale = locale
        func fmt(_ pattern: String) -> String { f.setLocalizedDateFormatFromTemplate(pattern); return f.string(from: now) }
        let week = Calendar(identifier: .iso8601).component(.weekOfYear, from: now)
        let values: [String: String] = [
            "datum": fmt("ddMMyyyy"), "uhrzeit": fmt("HHmm"), "wochentag": fmt("EEEE"), "kw": "\(week)",
            "jahr": fmt("yyyy"), "monat": fmt("MMMM"),
        ]
        return values
    }
}

// MARK: - Find in note (#9)

public enum FindInText {
    public struct Options: Equatable, Sendable {
        public var caseSensitive = false
        public var wholeWord = false
        public init(caseSensitive: Bool = false, wholeWord: Bool = false) {
            self.caseSensitive = caseSensitive
            self.wholeWord = wholeWord
        }
    }

    /// Ranges (UTF-16) of `query` in `text`; with `wholeWord` a match must not touch letters or digits.
    public static func ranges(of query: String, in text: String, options: Options = Options()) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let ns = text as NSString
        var out: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        let opts: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
        while search.length > 0 {
            let r = ns.range(of: query, options: opts, range: search)
            guard r.location != NSNotFound else { break }
            if !options.wholeWord || isWordBoundary(ns, r) { out.append(r) }
            let next = NSMaxRange(r)
            search = NSRange(location: next, length: ns.length - next)
        }
        return out
    }

    private static func isWordBoundary(_ ns: NSString, _ r: NSRange) -> Bool {
        func isWordChar(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length, let scalar = Unicode.Scalar(ns.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
        return !isWordChar(r.location - 1) && !isWordChar(NSMaxRange(r))
    }
}

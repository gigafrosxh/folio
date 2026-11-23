import Foundation

// MARK: - AI actions on selected text (#36)

/// What the context menu offers for a selection. Nothing changes until the user confirms the result.
public enum AITextAction: String, CaseIterable, Sendable {
    case explain, simplify, rewrite, quiz

    public var label: String {
        switch self {
        case .explain: return "Erklären"
        case .simplify: return "Vereinfachen"
        case .rewrite: return "Umschreiben"
        case .quiz: return "Lernfragen erstellen"
        }
    }

    /// Replaces the selection (a new version of it) or goes below it (something about it).
    public var replacesSelection: Bool { self == .simplify || self == .rewrite }

    public var instructions: String {
        let base = "Du arbeitest in der Notizen-App Folio. Antworte in der Sprache des Textes. Gib nur das Ergebnis aus, ohne Einleitung und ohne Anführungszeichen drumherum."
        switch self {
        case .explain: return base + " Erkläre den Text verständlich in wenigen Sätzen; nenne Fachbegriffe und was sie bedeuten."
        case .simplify: return base + " Formuliere den Text einfacher und kürzer, ohne Inhalt wegzulassen. Behalte Listen und Absätze bei."
        case .rewrite: return base + " Formuliere den Text klarer und flüssiger um. Inhalt, Ton und Aufbau bleiben gleich."
        case .quiz: return base + " Erstelle 3 bis 5 Lernfragen zum Text als nummerierte Liste, jeweils mit einer kurzen Antwort darunter, eingeleitet mit „Antwort:“."
        }
    }

    /// The prompt for `text`; very long selections are cut so small local models are not overwhelmed.
    public func prompt(for text: String, limit: Int = 6_000) -> String {
        let cut = text.count > limit ? String(text.prefix(limit)) + "\n[…]" : text
        return "Text:\n\"\"\"\n\(cut)\n\"\"\""
    }
}

// MARK: - Answers as blocks (#40)

/// An AI answer split into what becomes editable blocks: text (Markdown, formatted by the editor), code blocks
/// with their language, and tables.
public enum AnswerSegment: Equatable, Sendable {
    case text(String)
    case code(language: String, code: String)
    case table(header: [String], rows: [[String]])
}

public enum AnswerBlocks {
    public static func segments(of markdown: String) -> [AnswerSegment] {
        var out: [AnswerSegment] = []
        var text: [String] = []
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]
        func flushText() {
            let joined = text.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.text(joined)) }
            text = []
        }
        while let line = lines.popFirst() {
            if let block = code(opening: line, rest: &lines) ?? table(header: line, rest: &lines) {
                flushText()
                out.append(block)
            } else {
                text.append(line)
            }
        }
        flushText()
        return out
    }

    /// A fenced code block starting at `opening`; an unclosed fence runs to the end.
    static func code(opening line: String, rest lines: inout ArraySlice<String>) -> AnswerSegment? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
        let fence = String(trimmed.prefix(3))
        let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
        var code: [String] = []
        while let next = lines.popFirst(), !next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(next) }
        // Models sometimes fence a plain Markdown table; it still becomes a table (#226).
        if ["", "text", "markdown", "md"].contains(language), let table = fencedTable(code) { return table }
        return .code(language: language.isEmpty ? "text" : language, code: code.joined(separator: "\n"))
    }

    /// A fence whose only content is one Markdown table.
    static func fencedTable(_ code: [String]) -> AnswerSegment? {
        var rest = code.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }[...]
        guard let header = rest.popFirst(), let table = table(header: header, rest: &rest), rest.isEmpty else { return nil }
        return table
    }

    /// A Markdown table: a pipe row followed by a separator row (`|---|`).
    static func table(header line: String, rest lines: inout ArraySlice<String>) -> AnswerSegment? {
        guard isTableRow(line.trimmingCharacters(in: .whitespaces)), let separator = lines.first, isSeparator(separator) else { return nil }
        lines = lines.dropFirst()
        var rows: [[String]] = []
        while let next = lines.first, isTableRow(next.trimmingCharacters(in: .whitespaces)) {
            rows.append(cells(next))
            lines = lines.dropFirst()
        }
        let header = cells(line)
        return .table(header: header, rows: rows.map { normalized($0, count: header.count) })
    }

    static func isTableRow(_ line: String) -> Bool { line.hasPrefix("|") && line.dropFirst().contains("|") }

    static func isSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        // Only `\|` is an escape (a pipe inside a cell); every other backslash is content: paths, regexes, LaTeX (#230).
        var cells: [String] = [], current = ""
        var chars = Array(t)[...]
        while let ch = chars.popFirst() {
            if ch == "\\", chars.first == "|" {
                current.append(chars.removeFirst())
                continue
            }
            if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// Rows with fewer cells are padded, extra cells are kept (nothing the model wrote is dropped).
    static func normalized(_ row: [String], count: Int) -> [String] {
        row.count >= count ? row : row + Array(repeating: "", count: count - row.count)
    }
}

// MARK: - Tag suggestions (#37)

public enum TagSuggester {
    /// Tags for `text`, best first: tags already used in the library whose word appears in the note, then
    /// frequent capitalised words. Tags the note has are left out. Nothing is added without the user.
    public static func suggest(text: String, existing: [String], libraryTags: [(tag: String, count: Int)], limit: Int = 6) -> [String] {
        let have = Set(existing.map { $0.lowercased() })
        var out = Array(fromLibrary(text: text, have: have, libraryTags: libraryTags).prefix(limit))
        for tag in nouns(in: text) where out.count < limit {
            if !have.contains(tag) && !out.contains(tag) { out.append(tag) }
        }
        return out
    }

    /// Library tags that the note talks about, most used first (the last part of nested tags counts:
    /// projekt/folio → folio).
    static func fromLibrary(text: String, have: Set<String>, libraryTags: [(tag: String, count: Int)]) -> [String] {
        let words = Set(text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init))
        func mentioned(_ leaf: String) -> Bool {
            words.contains(leaf) || words.contains { $0.hasPrefix(leaf) && $0.count <= leaf.count + 3 }
        }
        return libraryTags.sorted { $0.count > $1.count }.map { $0.tag.lowercased() }.filter { key in
            let leaf = key.split(separator: "/").last.map(String.init) ?? key
            return !have.contains(key) && leaf.count >= 3 && mentioned(leaf)
        }
    }

    static let stopWords: Set<String> = [
        "diese", "dieser", "dieses", "eine", "einer", "einem", "einen", "aber", "auch", "dann", "denn", "noch", "nach", "über", "unter", "wenn", "weil", "dass", "sind", "wird",
        "werden", "haben", "kann", "können", "muss", "notiz", "notizen", "text"
    ]

    /// Capitalised words that come back, best first; a word only at sentence starts counts less.
    static func nouns(in text: String) -> [String] {
        var counts: [String: Int] = [:]
        let tokens = text.split { $0.isWhitespace || $0.isNewline }
        for (i, raw) in tokens.enumerated() {
            let word = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard word.count >= 4, word.first?.isUppercase == true, word.allSatisfy({ $0.isLetter || $0 == "-" }) else { continue }
            let afterSentenceEnd = i == 0 || tokens[i - 1].last.map { ".!?:".contains($0) } == true
            counts[word.lowercased(), default: 0] += afterSentenceEnd ? 1 : 2
        }
        return counts.filter { $0.value >= 3 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .compactMap { TagEdit.normalized($0.key) }
            .filter { !stopWords.contains($0) }
    }

    /// Tag names from a model's answer („rezept, kochen, #italien“), cleaned the way Folio writes tags.
    public static func parse(_ answer: String, limit: Int = 6) -> [String] {
        var out: [String] = []
        for part in answer.split(whereSeparator: { ",\n;".contains($0) }) {
            var p = part.trimmingCharacters(in: .whitespaces)
            while let f = p.first, "-*•0123456789.)".contains(f) {
                p.removeFirst()
                p = p.trimmingCharacters(in: .whitespaces)
            }
            guard let tag = TagEdit.normalized(p), !out.contains(tag), tag.count <= 30 else { continue }
            out.append(tag)
            if out.count >= limit { break }
        }
        return out
    }
}

/// Whether the user's own words ask the assistant to change notes (#381). Only then does the chat offer its note
/// tools: text inside notes (sources) can never switch them on, whatever it says.
public enum AssistantIntent {
    static let actionWords = [
        "anleg", "erstell", "neue notiz", "ergänz", "hinzufüg", "füg", "anhäng", "häng", "verknüpf", "verlink", "tagg", "tag ",
        "markier", "umbenenn", "benenn", "verschieb", "lege ", "leg ", "schreib", "notier",
        "create", "add ", "append", "link", "rename", "move", "tag"
    ]

    public static func asksForChanges(_ question: String) -> Bool {
        let q = " " + question.lowercased() + " "
        return actionWords.contains { q.contains($0) }
    }

    /// Most note changes one answer may make (#381): a request for "all notes" stops here and asks to continue.
    public static let maxActionsPerAnswer = 10
}

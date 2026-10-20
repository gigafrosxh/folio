import Foundation

// MARK: - Passages and context (#35, #38, #39)

/// A piece of a note the AI can see and cite: a paragraph or a few lines under a heading.
public struct Passage: Identifiable, Hashable, Codable, Sendable {
    public var noteID: UUID
    public var noteTitle: String
    /// Position within the note (0-based), used for ordering and linking.
    public var index: Int
    public var text: String
    public var id: String { "\(noteID.uuidString)#\(index)" }

    public init(noteID: UUID, noteTitle: String, index: Int, text: String) {
        self.noteID = noteID
        self.noteTitle = noteTitle
        self.index = index
        self.text = text
    }

    /// A short label for source lists: the first words of the passage.
    public var excerpt: String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > 90 ? String(flat.prefix(90)) + " …" : flat
    }
}

public enum Passages {
    /// Splits note text into passages of roughly `target` characters, breaking at blank lines, headings
    /// and line ends; very long lines are cut at sentence ends.
    public static func split(noteID: UUID, title: String, text: String, target: Int = 700) -> [Passage] {
        var out: [Passage] = []
        var current = ""
        func flush() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(Passage(noteID: noteID, noteTitle: title, index: out.count, text: t)) }
            current = ""
        }
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isHeading = trimmed.hasPrefix("#") || (trimmed.count < 60 && trimmed.hasSuffix(":"))
            if trimmed.isEmpty {
                if current.count > target / 3 { flush() }
                continue
            }
            if isHeading, current.count > 80 { flush() }
            while line.count > target {
                // Cut long lines at the last sentence end before the target.
                let head = String(line.prefix(target))
                let cut = head.range(of: ". ", options: .backwards).map { head.distance(from: head.startIndex, to: $0.upperBound) } ?? target
                current += (current.isEmpty ? "" : "\n") + String(line.prefix(cut))
                flush()
                line = String(line.dropFirst(cut))
            }
            if current.count + line.count > target { flush() }
            current += (current.isEmpty ? "" : "\n") + line
        }
        flush()
        return out
    }
}

/// Rough token count for the on-device model (German and English text average about 3.6 characters
/// per token; code and numbers are denser).
public enum TokenEstimate {
    public static func tokens(_ text: String) -> Int { Int((Double(text.count) / 3.6).rounded(.up)) }
}

/// What goes into one request and how much room it takes.
public struct ContextPlan: Sendable, Equatable {
    public var passages: [Passage]
    /// Passages that matched but did not fit.
    public var omitted: Int
    public var usedTokens: Int
    public var budget: Int
    public var notes: Int { Set(passages.map(\.noteID)).count }
}

public enum ContextBuilder {
    /// Total context of Apple's on-device model.
    public static let modelContext = 4096
    /// Room for the sources; the rest is instructions, recent conversation, the question and the answer.
    public static let sourceBudget = 2300

    /// Takes passages in the given order until the budget is used.
    public static func plan(_ candidates: [Passage], budget: Int = sourceBudget) -> ContextPlan {
        var used = 0
        var picked: [Passage] = []
        var omitted = 0
        for p in candidates {
            let cost = TokenEstimate.tokens(p.text) + 12
            if used + cost > budget {
                // A long first passage is shortened instead of dropped, so there is always some context.
                if picked.isEmpty, budget - used > 200 {
                    var short = p
                    short.text = String(p.text.prefix(Int(Double(budget - used - 16) * 3.6))) + " …"
                    picked.append(short)
                    used += TokenEstimate.tokens(short.text) + 12
                } else {
                    omitted += 1
                }
                continue
            }
            picked.append(p)
            used += cost
        }
        return ContextPlan(passages: picked, omitted: omitted, usedTokens: used, budget: budget)
    }

    /// The numbered source list for the prompt: "[1] Titel: text".
    public static func sourceBlock(_ plan: ContextPlan) -> String {
        plan.passages.enumerated().map { i, p in "[\(i + 1)] \(p.noteTitle.isEmpty ? "Notiz" : p.noteTitle):\n\(p.text)" }
            .joined(separator: "\n\n")
    }
}

// MARK: - Local search (#38)

/// Keyword search over passages (BM25), with light German/English normalization. Works without AI and
/// picks what the model gets to read.
public struct PassageIndex: Sendable {
    public private(set) var passages: [Passage] = []
    private var termFreqs: [[String: Int]] = []
    private var docFreq: [String: Int] = [:]
    private var avgLength: Double = 1

    public init(_ passages: [Passage]) {
        self.passages = passages
        termFreqs = passages.map { p in
            var tf: [String: Int] = [:]
            for t in Self.terms(p.noteTitle + " " + p.text) { tf[t, default: 0] += 1 }
            return tf
        }
        for tf in termFreqs { for t in tf.keys { docFreq[t, default: 0] += 1 } }
        avgLength = max(Double(termFreqs.map { $0.values.reduce(0, +) }.reduce(0, +)) / Double(max(passages.count, 1)), 1)
    }

    private static let stopwords: Set<String> = [
        "der", "die", "das", "und", "oder", "ein", "eine", "einer", "eines", "einem", "einen", "ist", "sind", "war", "in", "im",
        "zu", "zum", "zur", "mit", "von", "vom", "für", "auf", "an", "am", "aus", "bei", "den", "dem", "des", "es", "ich",
        "du", "wir", "sie", "er", "was", "wie", "wo", "wann", "welche", "welcher", "welches", "habe", "hat", "haben", "wird",
        "werden", "nicht", "auch", "noch", "nur", "so", "dass", "mein", "meine", "meinen", "meinem", "über", "the", "a",
        "an", "and", "or", "of", "to", "is", "are", "was", "what", "which", "how", "my", "for", "on", "with", "do", "did",
    ]

    /// Lowercased word stems without accents; very short words and stopwords are skipped.
    public static func terms(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
        return folded.split { !$0.isLetter && !$0.isNumber }.compactMap { raw in
            let w = String(raw)
            guard w.count >= 2, !stopwords.contains(w) else { return nil }
            return stem(w)
        }
    }

    /// Strips common German and English endings so "Rezepte", "Rezepten" and "Rezept" match.
    static func stem(_ w: String) -> String {
        guard w.count > 4, !w.allSatisfy(\.isNumber) else { return w }
        for suffix in ["ungen", "ung", "en", "er", "es", "e", "n", "s", "ing", "ed"] where w.hasSuffix(suffix) && w.count - suffix.count >= 4 {
            return String(w.dropLast(suffix.count))
        }
        return w
    }

    /// Passages ranked for `query`, best first; passages without any matching term are left out.
    public func search(_ query: String, limit: Int = 12) -> [(passage: Passage, score: Double)] {
        let q = Set(Self.terms(query))
        guard !q.isEmpty, !passages.isEmpty else { return [] }
        let n = Double(passages.count)
        let k1 = 1.4, b = 0.75
        var scored: [(Int, Double)] = []
        for (i, tf) in termFreqs.enumerated() {
            let length = Double(tf.values.reduce(0, +))
            var score = 0.0
            for t in q {
                guard let f = tf[t] else { continue }
                let df = Double(docFreq[t] ?? 0)
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                score += idf * (Double(f) * (k1 + 1)) / (Double(f) + k1 * (1 - b + b * length / avgLength))
            }
            // A match in the title counts extra.
            let titleTerms = Set(Self.terms(passages[i].noteTitle))
            score += Double(q.intersection(titleTerms).count) * 0.8
            if score > 0 { scored.append((i, score)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { (passages[$0.0], $0.1) }
    }
}

// MARK: - Citations (#35)

public enum CitationParser {
    /// Source numbers cited in an answer, in order of first appearance: "[1]", "[2, 3]", "[1][4]".
    public static func citations(in text: String, sourceCount: Int) -> [Int] {
        let regex = try! NSRegularExpression(pattern: #"\[(\d{1,2}(?:\s*[,;]\s*\d{1,2})*)\]"#)
        let ns = text as NSString
        var out: [Int] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            for part in ns.substring(with: m.range(at: 1)).split(whereSeparator: { $0 == "," || $0 == ";" }) {
                if let n = Int(part.trimmingCharacters(in: .whitespaces)), n >= 1, n <= sourceCount, !out.contains(n) { out.append(n) }
            }
        }
        return out
    }

    /// Turns "[2]" into Markdown links ("[[2]](folio://note/<id>?p=<index>)") so citations are clickable.
    public static func linked(_ text: String, sources: [Passage]) -> String {
        let regex = try! NSRegularExpression(pattern: #"\[(\d{1,2})\](?!\()"#)
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let n = Int(ns.substring(with: m.range(at: 1))) ?? 0
            if n >= 1, n <= sources.count {
                let p = sources[n - 1]
                result += "[[\(n)]](\(NoteLink.url(for: p.noteID).absoluteString)?p=\(p.index))"
            } else {
                result += ns.substring(with: m.range)
            }
            cursor = NSMaxRange(m.range)
        }
        return result + ns.substring(from: cursor)
    }
}

extension NoteLink {
    /// The passage index of a citation link ("folio://note/<id>?p=3").
    public static func passageIndex(from url: URL) -> Int? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "p" }?.value.flatMap(Int.init)
    }
}

// MARK: - Saved conversations (#33)

public struct ChatRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id: UUID
    public var role: Role
    public var text: String
    public var date: Date
    /// Sources the answer was given (numbered from 1 in this order).
    public var sources: [Passage]
    /// Context use of the answer, for the context display.
    public var usedTokens: Int?

    public init(id: UUID = UUID(), role: Role, text: String, date: Date = Date(), sources: [Passage] = [], usedTokens: Int? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.sources = sources
        self.usedTokens = usedTokens
    }
}

public struct ChatTranscript: Codable, Equatable, Sendable {
    public var messages: [ChatRecord] = []
    /// Further notes the user added to the conversation (for comparing).
    public var extraNotes: [UUID] = []
    public init(messages: [ChatRecord] = [], extraNotes: [UUID] = []) {
        self.messages = messages
        self.extraNotes = extraNotes
    }

    /// The last exchanges as plain text for the next prompt, limited to `budget` tokens (newest kept).
    public func recentTurns(budget: Int = 500) -> String {
        var parts: [String] = []
        var used = 0
        for m in messages.reversed() where !m.text.isEmpty {
            let text = m.text.count > 600 ? String(m.text.prefix(600)) + " …" : m.text
            let line = (m.role == .user ? "Nutzer: " : "Assistent: ") + text
            let cost = TokenEstimate.tokens(line)
            if used + cost > budget { break }
            parts.insert(line, at: 0)
            used += cost
        }
        return parts.joined(separator: "\n")
    }
}

/// Conversations stored next to the notes in `<library>/.folio/chats/<id>.json`; the library-wide chat
/// uses the file `library.json`.
public struct ChatArchive: Sendable {
    public let directory: URL

    public init(library: URL) { directory = LibraryData.folder(library, "chats") }

    private func url(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }

    public static func key(note: UUID?) -> String { note?.uuidString ?? "library" }

    public func load(_ key: String) -> ChatTranscript {
        let decoder = JSONDecoder()
        guard let data = try? Data(contentsOf: url(key)), let t = try? decoder.decode(ChatTranscript.self, from: data) else { return ChatTranscript() }
        return t
    }

    public func save(_ transcript: ChatTranscript, key: String) throws {
        if transcript.messages.isEmpty && transcript.extraNotes.isEmpty {
            try? FileManager.default.removeItem(at: url(key))
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(transcript).write(to: url(key), options: .atomic)
    }

    public func delete(_ key: String) { try? FileManager.default.removeItem(at: url(key)) }
}

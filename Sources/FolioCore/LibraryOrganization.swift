import Foundation

// MARK: - Sorting (#13)

/// How a note list is ordered. Pinned notes stay on top in every order.
public enum NoteSortMode: String, Codable, CaseIterable, Sendable {
    case modified, created, title, manual

    public var label: String {
        switch self {
        case .modified: return "Zuletzt bearbeitet"
        case .created: return "Erstellungsdatum"
        case .title: return "Titel"
        case .manual: return "Eigene Reihenfolge"
        }
    }

    /// Date groups („Heute“, „Gestern“ …) only make sense when the list is sorted by a date.
    public var groupsByDate: Bool { self == .modified || self == .created }
}

/// A user-chosen order of items (notes in a list, folders below a parent). Items that are not in the
/// order yet keep a sensible place: `newFirst` puts them in front (new notes show up on top), otherwise
/// they follow the ordered ones.
public enum ManualOrder {
    public static func apply<T, K: Hashable>(_ items: [T], order: [K], key: (T) -> K, newFirst: Bool) -> [T] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let known = items.filter { rank[key($0)] != nil }.sorted { rank[key($0)]! < rank[key($1)]! }
        let new = items.filter { rank[key($0)] == nil }
        return newFirst ? new + known : known + new
    }

    /// The order after moving `item` in front of `target` (nil = to the end) within `visible`, the list as shown.
    public static func moving<K: Hashable>(_ item: K, before target: K?, in visible: [K]) -> [K] {
        guard item != target else { return visible }
        var list = visible.filter { $0 != item }
        if let target, let i = list.firstIndex(of: target) { list.insert(item, at: i) } else { list.append(item) }
        return list
    }

    /// The order after moving `item` one place up (-1) or down (+1) within `visible`.
    public static func stepping<K: Hashable>(_ item: K, by delta: Int, in visible: [K]) -> [K] {
        guard let i = visible.firstIndex(of: item) else { return visible }
        let j = min(max(i + delta, 0), visible.count - 1)
        var list = visible
        list.remove(at: i)
        list.insert(item, at: j)
        return list
    }
}

// MARK: - Smart views (#14)

/// A saved search that lives in the sidebar.
public struct SmartView: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var filter: SearchFilter

    public init(id: UUID = UUID(), name: String, filter: SearchFilter) {
        self.id = id
        self.name = name
        self.filter = filter
    }

    /// A readable summary, e.g. „rezept · #kochen · Code · Letzte 7 Tage“.
    public var summary: String {
        var parts: [String] = []
        if !filter.text.isEmpty { parts.append("„\(filter.text)“") }
        parts += filter.tags.sorted().map { "#\($0)" }
        if let f = filter.folder { parts.append("Ordner \(f)") }
        parts += filter.types.sorted().compactMap { t in SearchFilter.contentTypes.first { $0.id == t }?.label }
        if filter.period != .any { parts.append(filter.period.label) }
        parts += filter.properties.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value == "*" ? "vorhanden" : $0.value)" }
        return parts.isEmpty ? "Alle Notizen" : parts.joined(separator: " · ")
    }
}

extension SearchFilter.Period: Codable {}

extension SearchFilter: Codable {
    private enum CodingKeys: String, CodingKey { case text, tags, folder, period, types, properties }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
                  tags: try c.decodeIfPresent(Set<String>.self, forKey: .tags) ?? [],
                  folder: try c.decodeIfPresent(String.self, forKey: .folder),
                  period: (try? c.decodeIfPresent(Period.self, forKey: .period)) ?? .any,
                  types: try c.decodeIfPresent(Set<String>.self, forKey: .types) ?? [])
        properties = try c.decodeIfPresent([String: String].self, forKey: .properties) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(tags.sorted(), forKey: .tags)
        try c.encodeIfPresent(folder, forKey: .folder)
        try c.encode(period, forKey: .period)
        try c.encode(types.sorted(), forKey: .types)
        try c.encode(properties, forKey: .properties)
    }
}

// MARK: - The library's own organization data (#13, #14, #15)

/// Order, favorites and smart views of a library, kept in `<library>/.folio/organization.json` so they
/// travel with the notes (sync, backup, another Mac). Note files themselves are not touched.
public struct LibraryOrganization: Codable, Equatable, Sendable {
    public var sortMode: NoteSortMode = .modified
    /// Favorite notes in their order (#15); independent of pinning.
    public var favorites: [UUID] = []
    /// Manual note order per list (see `listKey`).
    public var noteOrder: [String: [UUID]] = [:]
    /// Manual folder order per parent folder, relative to the library ("" = top level); names of the subfolders.
    public var folderOrder: [String: [String]] = [:]
    public var smartViews: [SmartView] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sortMode = (try? c.decodeIfPresent(NoteSortMode.self, forKey: .sortMode)) ?? .modified
        favorites = try c.decodeIfPresent([UUID].self, forKey: .favorites) ?? []
        noteOrder = try c.decodeIfPresent([String: [UUID]].self, forKey: .noteOrder) ?? [:]
        folderOrder = try c.decodeIfPresent([String: [String]].self, forKey: .folderOrder) ?? [:]
        smartViews = try c.decodeIfPresent([SmartView].self, forKey: .smartViews) ?? []
    }

    public func isFavorite(_ id: UUID) -> Bool { favorites.contains(id) }

    public mutating func toggleFavorite(_ id: UUID) {
        if let i = favorites.firstIndex(of: id) { favorites.remove(at: i) } else { favorites.append(id) }
    }

    public static func file(in library: URL) -> URL {
        library.appendingPathComponent(LibraryData.folderName, isDirectory: true).appendingPathComponent("organization.json")
    }

    public enum LoadResult: Equatable, Sendable {
        case loaded(LibraryOrganization)
        /// No file yet: a library that was never organized.
        case missing
        /// The file could not be read; it was set aside as `organization-defekt-<date>.json`.
        case unreadable(keptAs: String?)
    }

    /// Reads the library's organization. An unreadable file is renamed, never overwritten, so nothing is lost.
    public static func load(from library: URL, now: Date = Date()) -> LoadResult {
        let url = file(in: library)
        guard let data = try? Data(contentsOf: url) else { return .missing }
        if let org = try? JSONDecoder().decode(LibraryOrganization.self, from: data) { return .loaded(org) }
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let kept = url.deletingLastPathComponent().appendingPathComponent("organization-defekt-\(stamp).json")
        let ok = (try? FileManager.default.moveItem(at: url, to: kept)) != nil
        return .unreadable(keptAs: ok ? kept.lastPathComponent : nil)
    }

    public func save(to library: URL) throws {
        let url = Self.file(in: library)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    /// Drops ids of notes that no longer exist anywhere (not even in the trash) and empty orders.
    public mutating func prune(keeping ids: Set<UUID>) {
        favorites.removeAll { !ids.contains($0) }
        noteOrder = noteOrder.mapValues { $0.filter(ids.contains) }.filter { !$0.value.isEmpty }
    }
}

// MARK: - Note statistics (#19)

/// Numbers about one note's content.
public struct NoteStatistics: Equatable, Sendable {
    public var characters = 0
    public var charactersWithoutSpaces = 0
    public var words = 0
    public var paragraphs = 0
    public var codeBlocks = 0
    /// Lines of code that are not empty.
    public var codeLines = 0

    public init() {}

    /// `texts`: the text of the note's text blocks; `code`: the source of its code blocks.
    public init(texts: [String], code: [String]) {
        for t in texts {
            characters += t.count
            charactersWithoutSpaces += t.filter { !$0.isWhitespace }.count
            words += Self.wordCount(t)
            paragraphs += t.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.count
        }
        codeBlocks = code.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        codeLines = code.reduce(0) { $0 + $1.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.count }
    }

    /// Words as people count them: runs of letters or digits („E-Mail“ and „1.000“ are one word each); list
    /// bullets and checkboxes are not words.
    public static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.filter { w in w.contains { $0.isLetter || $0.isNumber } }.count
    }

    /// Minutes to read at about 200 words per minute, at least one when there is text.
    public var readingMinutes: Int { words == 0 ? 0 : max(1, Int((Double(words) / 200).rounded())) }
}

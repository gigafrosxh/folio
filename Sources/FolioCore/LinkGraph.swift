import Foundation

// MARK: - Wiki links (#115, #120)

/// `[[Notiz]]`, `[[Notiz|Anzeigetext]]` and embeds `![[Notiz]]` in plain text.
public struct WikiLink: Equatable, Sendable {
    /// Range of the whole `[[…]]` (with the `!` for embeds) in UTF-16 units, for NSString/NSTextView.
    public var range: NSRange
    public var target: String
    public var alias: String?
    public var isEmbed: Bool

    public var display: String { alias ?? target }

    private static let regex = try! NSRegularExpression(pattern: #"(!?)\[\[([^\[\]\|\n]+?)(?:\|([^\[\]\n]+?))?\]\]"#)

    public static func find(in text: String) -> [WikiLink] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let target = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }
            let alias = m.range(at: 3).location == NSNotFound ? nil : ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
            return WikiLink(range: m.range, target: target, alias: alias?.isEmpty == true ? nil : alias,
                            isEmbed: m.range(at: 1).length > 0)
        }
    }

    /// Distinct link targets of a text, embeds included (they connect notes in the graph too), in order.
    public static func targets(in text: String) -> [String] {
        var seen = Set<String>()
        return find(in: text).map(\.target).filter { seen.insert(key($0)).inserted }
    }

    /// How titles are compared: case-, accent- and surrounding-space-insensitive.
    public static func key(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// `folio://wiki/<Titel>` – the link a `[[Titel]]` gets in the editor.
    public static func url(for target: String) -> URL {
        var c = URLComponents()
        c.scheme = NoteLink.scheme
        c.host = "wiki"
        c.path = "/" + target
        return c.url ?? URL(string: "folio://wiki")!
    }

    public static func target(from url: URL) -> String? {
        guard url.scheme?.lowercased() == NoteLink.scheme, url.host()?.lowercased() == "wiki" else { return nil }
        let t = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return t.isEmpty ? nil : t
    }
}

// MARK: - Link index (#119)

/// Notes and the links between them: `folio://note/<id>` links and `[[Titel]]` links resolved by
/// title. Updated per note when one changes, is renamed or deleted, so large libraries never need
/// a full rescan.
public struct LinkIndex: Sendable {
    public struct Node: Equatable, Sendable {
        public var id: UUID
        public var title: String
        public var folder: String
        public var tags: [String]
        public var modified: Date

        public init(id: UUID, title: String, folder: String, tags: [String], modified: Date) {
            self.id = id
            self.title = title
            self.folder = folder
            self.tags = tags
            self.modified = modified
        }
    }

    public private(set) var nodes: [UUID: Node] = [:]
    /// Outgoing link targets as stored in the notes (ids and wiki titles), resolved on demand.
    private var idLinks: [UUID: Set<UUID>] = [:]
    private var wikiLinks: [UUID: Set<String>] = [:]
    /// Title key → note ids with that title (several notes may share one).
    private var byTitle: [String: Set<UUID>] = [:]

    public init() {}

    public init(_ notes: [(meta: NoteMetadata, folder: String)]) {
        for n in notes { update(n.meta, folder: n.folder) }
    }

    /// Adds or replaces one note.
    public mutating func update(_ meta: NoteMetadata, folder: String) {
        remove(meta.id)
        nodes[meta.id] = Node(id: meta.id, title: meta.title, folder: folder, tags: meta.tags, modified: meta.modified)
        byTitle[WikiLink.key(meta.title), default: []].insert(meta.id)
        idLinks[meta.id] = Set(meta.links).subtracting([meta.id])
        wikiLinks[meta.id] = Set((meta.wikiLinks ?? WikiLink.targets(in: meta.searchText)).map(WikiLink.key))
    }

    public mutating func remove(_ id: UUID) {
        if let old = nodes[id] {
            let k = WikiLink.key(old.title)
            byTitle[k]?.remove(id)
            if byTitle[k]?.isEmpty == true { byTitle[k] = nil }
        }
        nodes[id] = nil
        idLinks[id] = nil
        wikiLinks[id] = nil
    }

    /// The note a `[[Titel]]` points to; with several of the same title the most recently changed.
    public func resolve(_ title: String) -> UUID? {
        byTitle[WikiLink.key(title)]?.max { (nodes[$0]?.modified ?? .distantPast) < (nodes[$1]?.modified ?? .distantPast) }
    }

    /// Notes `id` links to (existing ones only, without itself).
    public func outgoing(_ id: UUID) -> Set<UUID> {
        var out = (idLinks[id] ?? []).filter { nodes[$0] != nil }
        for t in wikiLinks[id] ?? [] { if let r = byTitle[t], let best = resolve(t), !r.isEmpty { out.insert(best) } }
        out.remove(id)
        return out
    }

    /// `[[Titel]]` links of `id` whose note does not exist yet (#115).
    public func unresolved(_ id: UUID) -> [String] {
        (wikiLinks[id] ?? []).filter { byTitle[$0] == nil }.sorted()
    }

    /// Notes linking to `id`.
    public func backlinks(_ id: UUID) -> Set<UUID> {
        Set(nodes.keys.filter { $0 != id && outgoing($0).contains(id) })
    }

    /// Undirected edges, each once (smaller id first).
    public func edges() -> [(UUID, UUID)] {
        var seen = Set<String>()
        var result: [(UUID, UUID)] = []
        for a in nodes.keys {
            for b in outgoing(a) {
                let pair = a.uuidString < b.uuidString ? (a, b) : (b, a)
                if seen.insert(pair.0.uuidString + pair.1.uuidString).inserted { result.append(pair) }
            }
        }
        return result
    }

    /// Notes within `depth` links of `id` in either direction (#111); cycles are fine.
    public func neighborhood(of id: UUID, depth: Int) -> Set<UUID> {
        guard nodes[id] != nil else { return [] }
        var adjacency: [UUID: Set<UUID>] = [:]
        for (a, b) in edges() { adjacency[a, default: []].insert(b); adjacency[b, default: []].insert(a) }
        var seen: Set<UUID> = [id]
        var frontier: Set<UUID> = [id]
        for _ in 0..<max(0, depth) {
            frontier = Set(frontier.flatMap { adjacency[$0] ?? [] }).subtracting(seen)
            if frontier.isEmpty { break }
            seen.formUnion(frontier)
        }
        return seen
    }

    /// Notes without any link in or out (#114).
    public func orphans() -> Set<UUID> {
        var linked = Set<UUID>()
        for (a, b) in edges() { linked.insert(a); linked.insert(b) }
        return Set(nodes.keys).subtracting(linked)
    }

    /// Shortest path between two notes (undirected), for highlighting (#114).
    public func path(from a: UUID, to b: UUID) -> [UUID]? {
        guard nodes[a] != nil, nodes[b] != nil else { return nil }
        if a == b { return [a] }
        var adjacency: [UUID: Set<UUID>] = [:]
        for (x, y) in edges() { adjacency[x, default: []].insert(y); adjacency[y, default: []].insert(x) }
        var previous: [UUID: UUID] = [:]
        var queue = [a]
        var seen: Set<UUID> = [a]
        while !queue.isEmpty {
            let n = queue.removeFirst()
            for m in adjacency[n] ?? [] where seen.insert(m).inserted {
                previous[m] = n
                if m == b {
                    var path = [b]
                    while let p = previous[path[0]] { path.insert(p, at: 0) }
                    return path
                }
                queue.append(m)
            }
        }
        return nil
    }
}

// MARK: - Unlinked mentions (#112)

public enum Mentions {
    /// Ranges (UTF-16) where `title` appears as a whole word in `text`, outside `[[…]]` links.
    public static func ranges(of title: String, in text: String) -> [NSRange] {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3 else { return [] }   // „Ab“ would be everywhere
        let ns = text as NSString
        let linked = WikiLink.find(in: text).map(\.range)
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: t) + "(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
            .filter { r in !linked.contains { NSIntersectionRange($0, r).length > 0 } }
    }

    /// Notes mentioning the title of `id` without linking to it.
    public static func unlinked(to id: UUID, title: String, in notes: [NoteMetadata], index: LinkIndex) -> [UUID] {
        let linking = index.backlinks(id)
        return notes.filter { $0.id != id && !linking.contains($0.id) && !ranges(of: title, in: $0.searchText).isEmpty }.map(\.id)
    }
}

// MARK: - Graph layout (#110)

/// A force-directed layout: linked notes attract, all notes repel. Deterministic for the same input,
/// so the graph does not jump around between openings.
public enum GraphLayout {
    public static func compute(nodes: [UUID], edges: [(UUID, UUID)], iterations: Int = 300,
                               previous: [UUID: CGPoint] = [:]) -> [UUID: CGPoint] {
        let n = nodes.count
        guard n > 0 else { return [:] }
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1, $0) })
        var pos = [CGPoint](repeating: .zero, count: n)
        for (i, id) in nodes.enumerated() {
            if let p = previous[id] { pos[i] = p; continue }
            // Golden-angle spiral: a stable, even start without randomness.
            let r = 30 * sqrt(Double(i) + 0.5)
            let a = Double(i) * 2.399963
            pos[i] = CGPoint(x: r * cos(a), y: r * sin(a))
        }
        let links = edges.compactMap { e -> (Int, Int)? in
            guard let a = index[e.0], let b = index[e.1], a != b else { return nil }
            return (a, b)
        }
        let ideal = 60.0
        var temperature = 40.0
        // Big libraries: fewer rounds keep opening the graph fast.
        let rounds = n > 800 ? min(iterations, 80) : n > 300 ? min(iterations, 150) : iterations
        for _ in 0..<rounds {
            var disp = [CGVector](repeating: .zero, count: n)
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var dx = pos[i].x - pos[j].x, dy = pos[i].y - pos[j].y
                    var d2 = dx * dx + dy * dy
                    if d2 < 0.01 { dx = 0.1 * Double(i - j); dy = 0.1; d2 = dx * dx + dy * dy }
                    if d2 > 250_000 { continue }   // far apart: no noticeable push
                    let f = ideal * ideal / d2
                    disp[i].dx += dx * f; disp[i].dy += dy * f
                    disp[j].dx -= dx * f; disp[j].dy -= dy * f
                }
            }
            for (a, b) in links {
                let dx = pos[a].x - pos[b].x, dy = pos[a].y - pos[b].y
                let d = max(sqrt(dx * dx + dy * dy), 0.01)
                let f = d / ideal
                disp[a].dx -= dx * f; disp[a].dy -= dy * f
                disp[b].dx += dx * f; disp[b].dy += dy * f
            }
            for i in 0..<n {
                // Gentle pull to the center keeps unconnected parts on screen.
                disp[i].dx -= pos[i].x * 0.06
                disp[i].dy -= pos[i].y * 0.06
                let len = max(sqrt(disp[i].dx * disp[i].dx + disp[i].dy * disp[i].dy), 0.0001)
                let step = min(len, temperature)
                pos[i].x += disp[i].dx / len * step
                pos[i].y += disp[i].dy / len * step
            }
            temperature = max(temperature * 0.97, 1)
        }
        return Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1, pos[$0]) })
    }
}

// MARK: - Template variables (#118)

/// The placeholders of `TemplateText` (`{{datum}}`, `{{uhrzeit}}`, `{{wochentag}}`, `{{kw}}`, `{{jahr}}`,
/// `{{monat}}`) plus `{{titel}}` and `{{cursor}}`, English names (`date`, `time`, `weekday`, `title`) and
/// a date format after a colon: `{{datum:yyyy-MM-dd}}`.
public enum TemplateVariables {
    public struct Context: Sendable {
        public var date: Date
        public var title: String
        public var locale: Locale
        public init(date: Date = Date(), title: String, locale: Locale = Locale(identifier: "de_DE")) {
            self.date = date
            self.title = title
            self.locale = locale
        }
    }

    public static let cursorMarker = "{{cursor}}"
    private static let regex = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-zäöüÄÖÜ]+)\s*(?::([^}]+))?\}\}"#)

    /// Ranges of known variables and what they become; `{{cursor}}` becomes "" (its place is the cursor).
    public static func replacements(in text: String, context: Context) -> [(range: NSRange, value: String, isCursor: Bool)] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            let format = m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            func formatted(_ f: String) -> String {
                let df = DateFormatter()
                df.locale = context.locale
                df.dateFormat = f
                return df.string(from: context.date)
            }
            switch name {
            // Fixed formats, so a template gives the same text on every Mac.
            case "datum", "date": return (m.range, formatted(format ?? "dd.MM.yyyy"), false)
            case "uhrzeit", "time": return (m.range, formatted(format ?? "HH:mm"), false)
            case "wochentag", "weekday": return (m.range, formatted("EEEE"), false)
            case "kw", "week": return (m.range, "\(Calendar(identifier: .iso8601).component(.weekOfYear, from: context.date))", false)
            case "jahr", "year": return (m.range, formatted("yyyy"), false)
            case "monat", "month": return (m.range, formatted("MMMM"), false)
            case "titel", "title": return (m.range, context.title, false)
            case "cursor": return (m.range, "", true)
            default: return nil   // unknown names stay as written
            }
        }
    }

    /// Plain text with variables filled in, and where the cursor goes (UTF-16 offset).
    public static func apply(_ text: String, context: Context) -> (text: String, cursor: Int?) {
        let m = NSMutableAttributedString(string: text)
        let cursor = apply(to: m, context: context)
        return (m.string, cursor)
    }

    /// Fills in variables in rich text, keeping each placeholder's formatting; returns the cursor offset.
    @discardableResult
    public static func apply(to text: NSMutableAttributedString, context: Context) -> Int? {
        var cursor: Int?
        for r in replacements(in: text.string, context: context).reversed() {
            text.replaceCharacters(in: r.range, with: r.value)
            if r.isCursor { cursor = r.range.location }
            else if let c = cursor, r.range.location < c { cursor = c - r.range.length + (r.value as NSString).length }
        }
        return cursor
    }
}

// MARK: - Daily notes (#117)

public enum DailyNote {
    /// „2026-10-21“ – sortable and unique per day; also the file name.
    public static func title(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - 3D graph and folders (#132, #133)

public extension GraphLayout {
    /// The same forces in three dimensions; starts on a Fibonacci sphere, deterministic.
    static func compute3D(nodes: [UUID], edges: [(UUID, UUID)], iterations: Int = 300,
                          previous: [UUID: SIMD3<Double>] = [:]) -> [UUID: SIMD3<Double>] {
        let n = nodes.count
        guard n > 0 else { return [:] }
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1, $0) })
        var pos = [SIMD3<Double>](repeating: .zero, count: n)
        for (i, id) in nodes.enumerated() {
            if let p = previous[id] { pos[i] = p; continue }
            let y = n == 1 ? 0 : 1 - 2 * (Double(i) + 0.5) / Double(n)
            let r = (1 - y * y).squareRoot()
            let a = Double(i) * 2.399963
            let radius = 40 * Double(n).squareRoot()
            pos[i] = SIMD3(cos(a) * r, y, sin(a) * r) * radius
        }
        let links = edges.compactMap { e -> (Int, Int)? in
            guard let a = index[e.0], let b = index[e.1], a != b else { return nil }
            return (a, b)
        }
        let ideal = 60.0
        var temperature = 40.0
        let rounds = n > 800 ? min(iterations, 80) : n > 300 ? min(iterations, 150) : iterations
        for _ in 0..<rounds {
            var disp = [SIMD3<Double>](repeating: .zero, count: n)
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var d = pos[i] - pos[j]
                    var d2 = (d * d).sum()
                    if d2 < 0.01 { d = SIMD3(0.1 * Double(i - j), 0.1, 0.05); d2 = (d * d).sum() }
                    if d2 > 250_000 { continue }
                    let f = d * (ideal * ideal / d2)
                    disp[i] += f
                    disp[j] -= f
                }
            }
            for (a, b) in links {
                let d = pos[a] - pos[b]
                let len = max((d * d).sum().squareRoot(), 0.01)
                let f = d * (len / ideal)
                disp[a] -= f
                disp[b] += f
            }
            for i in 0..<n {
                disp[i] -= pos[i] * 0.06
                let len = max((disp[i] * disp[i]).sum().squareRoot(), 0.0001)
                pos[i] += disp[i] / len * min(len, temperature)
            }
            temperature = max(temperature * 0.97, 1)
        }
        return Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1, pos[$0]) })
    }

    /// A point after turning the graph (yaw around the vertical, pitch around the horizontal axis),
    /// with perspective: `scale` < 1 is farther away, `depth` sorts drawing back to front.
    static func project(_ p: SIMD3<Double>, yaw: Double, pitch: Double, camera: Double = 900) -> (x: Double, y: Double, scale: Double, depth: Double) {
        let x1 = p.x * cos(yaw) + p.z * sin(yaw)
        let z1 = -p.x * sin(yaw) + p.z * cos(yaw)
        let y2 = p.y * cos(pitch) - z1 * sin(pitch)
        let z2 = p.y * sin(pitch) + z1 * cos(pitch)
        let scale = camera / max(camera - z2, 50)
        return (x1 * scale, y2 * scale, scale, z2)
    }
}

/// Folders as graph nodes (#132): every note is linked to its folder, every folder to its parent.
public enum FolderGraph {
    /// A stable id per folder path, so folder nodes keep their place between layouts.
    public static func id(for path: String) -> UUID {
        var h1: UInt64 = 0xcbf29ce484222325, h2: UInt64 = 0x84222325cbf29ce4
        for b in ("folder:" + path).utf8 {
            h1 = (h1 ^ UInt64(b)) &* 0x100000001b3
            h2 = (h2 &+ UInt64(b)) &* 0x9E3779B97F4A7C15
        }
        let bytes = withUnsafeBytes(of: h1.bigEndian) { Array($0) } + withUnsafeBytes(of: h2.bigEndian) { Array($0) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Folder nodes (id → path) and the edges note→folder and folder→parent for the given notes.
    public static func augment(notes: [(id: UUID, folder: String)]) -> (folders: [UUID: String], edges: [(UUID, UUID)]) {
        var folders: [UUID: String] = [:]
        var edges: [(UUID, UUID)] = []
        var linkedFolders = Set<String>()
        for note in notes where !note.folder.isEmpty {
            edges.append((note.id, id(for: note.folder)))
            var path = note.folder
            while !path.isEmpty {
                folders[id(for: path)] = path
                guard linkedFolders.insert(path).inserted else { break }
                guard let slash = path.lastIndex(of: "/") else { break }
                let parent = String(path[..<slash])
                edges.append((id(for: path), id(for: parent)))
                path = parent
            }
        }
        return (folders, edges)
    }
}

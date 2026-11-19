import Foundation

/// ERD-Ultra project files (`.erdu`, JSON) embedded as ER blocks (#204).
///
/// Folio keeps the whole file as the block's source, so a note shows its diagram without the original file. Drawing
/// happens in the render page with ERD-Ultra's own renderer (`Resources/Web/erd/erdu-render.js`); this type only checks
/// files before they are taken in and pulls out the names for the note search.
public enum ErduDocument {
    public static let bundleIdentifier = "io.github.gigafrosxh.erdultra"
    public static let typeIdentifier = "io.github.gigafrosxh.erdultra.erdu"
    public static let fileExtension = "erdu"
    /// Highest file version the bundled renderer understands.
    public static let supportedVersion = 1
    /// ERD-Ultra files are a few dozen KB; anything this large is not one.
    public static let maxSize = 8 << 20

    /// The views a block can show; stored in the block's `mode`.
    public enum View: String, CaseIterable, Sendable {
        case er, rel, sql
        public var title: String {
            switch self {
            case .er: return "ER-Diagramm"
            case .rel: return "Relationales Schema"
            case .sql: return "SQL-DDL"
            }
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case tooLarge
        case notJSON
        case notErdu
        case newerVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .tooLarge: return "Die Datei ist zu groß für eine ERD-Ultra-Datei."
            case .notJSON, .notErdu: return "Keine gültige ERD-Ultra-Datei (.erdu)."
            case .newerVersion(let v): return "Datei stammt aus einer neueren ERD-Ultra-Version (Format \(v))."
            }
        }
    }

    public struct Summary: Sendable, Equatable {
        public var entities: Int
        public var relationships: Int
        public var tables: Int
        public var dialect: String?
        /// Entity, relationship, attribute, table and column names (for the search).
        public var names: [String]
    }

    /// Checks a file before it is embedded or replaces an embedded one; returns the text to store.
    public static func validate(_ data: Data) throws -> (text: String, summary: Summary) {
        guard data.count <= maxSize else { throw Failure.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.notJSON }
        return (text, try summary(of: text))
    }

    public static func summary(of text: String) throws -> Summary {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)), let root = object as? [String: Any] else {
            throw Failure.notJSON
        }
        guard root["format"] as? String == "erd-ultra" else { throw Failure.notErdu }
        let version = (root["version"] as? NSNumber)?.intValue ?? 0
        guard version >= 1 else { throw Failure.notErdu }
        guard version <= supportedVersion else { throw Failure.newerVersion(version) }
        let nodes = ((root["er"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let tables = ((root["rel"] as? [String: Any])?["tables"] as? [[String: Any]]) ?? []
        var names: [String] = nodes.filter { ["entity", "relationship", "attribute"].contains($0["kind"] as? String ?? "") }
            .compactMap { $0["name"] as? String }
        for table in tables {
            if let n = table["name"] as? String { names.append(n) }
            names += ((table["columns"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        }
        var seen = Set<String>()
        names = names.filter { !$0.isEmpty && seen.insert($0).inserted }
        return Summary(entities: nodes.filter { $0["kind"] as? String == "entity" }.count,
                       relationships: nodes.filter { $0["kind"] as? String == "relationship" }.count,
                       tables: tables.count, dialect: root["dialect"] as? String, names: names)
    }

    /// Search text of a block: the names, one per line; empty for broken files.
    public static func searchText(of text: String) -> String {
        ((try? summary(of: text))?.names ?? []).joined(separator: "\n")
    }
}

import Foundation

/// Reads the tabular output of `sqlcmd` (#148). The tool cannot distinguish SQL NULL from the string "NULL", or
/// unescaped separators in values. Newlines are recoverable until the expected column count is reached;
/// last-column newlines are ambiguous.
struct SQLCMDOutputParser {
    private static let separator = "\u{001F}"
    private let lines: [String]
    private var index = 0
    private var current: QueryResult?
    private var last: QueryResult?
    private var changes: String?
    private var pending: String?

    init(_ output: String) {
        lines = output.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    mutating func parse() throws -> QueryResult {
        while index < lines.count {
            if startsResultSet {
                finishResultSet()
                current = QueryResult(columns: lines[index].components(separatedBy: Self.separator))
                index += 2
            } else {
                try consume(lines[index])
                index += 1
            }
        }
        guard pending == nil else { throw DatabaseError.queryFailed("Unvollständige SQL-Server-Ausgabe.") }
        finishResultSet()
        return last ?? QueryResult(message: summary)
    }

    private var summary: String {
        guard let changes else { return "Ausgeführt." }
        return changes == "1" ? "1 Zeile geändert" : "\(changes) Zeilen geändert"
    }

    private var startsResultSet: Bool {
        pending == nil && index + 1 < lines.count && Self.isDashes(lines[index + 1])
    }

    private static func isDashes(_ line: String) -> Bool {
        line.components(separatedBy: separator).allSatisfy { field in
            let value = field.trimmingCharacters(in: .whitespaces)
            return !value.isEmpty && value.allSatisfy { $0 == "-" }
        }
    }

    private mutating func finishResultSet() {
        guard let result = current else { return }
        if result.columns == ["__folio_changes"] { changes = result.rows.first?.first ?? nil }
        else if !result.rows.isEmpty { last = result }
        current = nil
    }

    private mutating func consume(_ line: String) throws {
        guard let count = current?.columns.count, pending != nil || !line.isEmpty else { return }
        let record = pending.map { $0 + "\n" + line } ?? line
        let fields = record.components(separatedBy: Self.separator)
        guard fields.count >= count else { pending = record; return }
        guard fields.count == count else { throw DatabaseError.queryFailed("Ungültige SQL-Server-Ausgabe.") }
        current?.rows.append(fields.map { $0 == "NULL" ? nil : $0 })
        pending = nil
    }
}

/// Splits psql's CSV output into records; quoting and NULL detection live here (#148).
struct CSVRecordReader {
    /// A blank line, which separates result sets.
    static let setSeparator: [String?] = [nil]

    private let nullMarker: String?
    private var records: [[String?]] = []
    private var row: [String?] = []
    private var field = ""
    private var quoted = false
    private var wasQuoted = false

    init(nullMarker: String?) { self.nullMarker = nullMarker }

    mutating func read(_ text: String) throws -> [[String?]] {
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            i += consume(chars[i], next: i + 1 < chars.count ? chars[i + 1] : nil)
        }
        guard !quoted else { throw DatabaseError.queryFailed("Ungültige CSV-Ausgabe.") }
        if !field.isEmpty || wasQuoted || !row.isEmpty { endRecord() }
        return records
    }

    /// Handles one character and says how many were used.
    private mutating func consume(_ c: Character, next: Character?) -> Int {
        if c == "\"" { return consumeQuote(next: next) }
        if quoted { field.append(c); return 1 }
        switch c {
        case ",": endField()
        case "\n", "\r\n", "\r": endLine()
        default: field.append(c)
        }
        return 1
    }

    private mutating func consumeQuote(next: Character?) -> Int {
        if quoted && next == "\"" {
            field.append("\"")
            return 2
        }
        quoted.toggle()
        wasQuoted = true
        return 1
    }

    private mutating func endLine() {
        if row.isEmpty && field.isEmpty && !wasQuoted { records.append(Self.setSeparator) } else { endRecord() }
        row = []
    }

    private mutating func endRecord() {
        endField()
        records.append(row)
    }

    /// With a NULL marker, an unquoted empty field is an empty string (psql writes '' unquoted).
    private mutating func endField() {
        row.append(field.isEmpty && !wasQuoted && nullMarker == nil ? nil : field)
        field = ""
        wasQuoted = false
    }
}

/// Turns CSV records into result sets. psql has no explicit set boundaries: equal-width consecutive sets remain
/// ambiguous. A per-session NULL marker keeps single-column NULL rows distinct from blank separators.
struct CSVResultSets {
    private let nullMarker: String?
    private var current: QueryResult?
    private var last: QueryResult?

    init(nullMarker: String?) { self.nullMarker = nullMarker }

    mutating func assemble(_ records: [[String?]]) -> QueryResult {
        records.forEach { add($0) }
        if let current, !current.rows.isEmpty { return current }
        return last ?? current ?? QueryResult(message: "Ausgeführt.")
    }

    private mutating func add(_ record: [String?]) {
        if record == CSVRecordReader.setSeparator {
            closeSet()
            current = nil
        } else if record.count != current?.columns.count {
            closeSet()
            current = QueryResult(columns: record.map { $0 ?? "" })
        } else {
            current?.rows.append(record.map { $0 == nullMarker ? nil : $0 })
        }
    }

    private mutating func closeSet() {
        if let value = current, !value.rows.isEmpty { last = value }
    }
}

/// Reads JSON result sets while keeping the column order, which `JSONSerialization` would lose.
struct OrderedJSON {
    private let bytes: [UInt8]
    private var index = 0
    private static let quote: UInt8 = 34, backslash: UInt8 = 92, comma: UInt8 = 44, colon: UInt8 = 58
    private static let openArray: UInt8 = 91, closeArray: UInt8 = 93, openObject: UInt8 = 123, closeObject: UInt8 = 125

    init(_ text: String) { bytes = Array(text.utf8) }

    mutating func results() throws -> [QueryResult] {
        var results: [QueryResult] = []
        whitespace()
        while index < bytes.count {
            results.append(try resultSet())
            whitespace()
        }
        return results
    }

    private mutating func resultSet() throws -> QueryResult {
        try consume(Self.openArray)
        whitespace()
        var result = QueryResult()
        repeat {
            guard hasMore(before: Self.closeArray) else { break }
            let (keys, values) = try object()
            if result.rows.isEmpty { result.columns = keys }
            result.rows.append(values)
            whitespace()
        } while skipComma()
        try consume(Self.closeArray)
        return result
    }

    private mutating func object() throws -> ([String], [String?]) {
        try consume(Self.openObject)
        whitespace()
        var keys: [String] = [], values: [String?] = []
        repeat {
            guard hasMore(before: Self.closeObject) else { break }
            keys.append(try scalar() ?? "")
            try consume(Self.colon)
            values.append(try scalar())
            whitespace()
        } while skipComma()
        try consume(Self.closeObject)
        return (keys, values)
    }

    private func hasMore(before close: UInt8) -> Bool { index < bytes.count && bytes[index] != close }

    private mutating func skipComma() -> Bool {
        guard index < bytes.count, bytes[index] == Self.comma else { return false }
        index += 1
        return true
    }

    private mutating func whitespace() {
        while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) throws {
        whitespace()
        guard index < bytes.count, bytes[index] == byte else { throw DatabaseError.queryFailed("Ungültige JSON-Ausgabe.") }
        index += 1
    }

    private mutating func scalar() throws -> String? {
        whitespace()
        let start = index
        if index < bytes.count && bytes[index] == Self.quote { skipString() } else { skipBareValue() }
        guard index > start, index <= bytes.count else { throw DatabaseError.queryFailed("Ungültiger JSON-Wert.") }
        let data = Data(bytes[start..<index])
        let value = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        if value is NSNull { return nil }
        return value as? String ?? String(decoding: data, as: UTF8.self)
    }

    private mutating func skipString() {
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == Self.backslash { index += 1 } else if byte == Self.quote { return }
        }
    }

    private mutating func skipBareValue() {
        while index < bytes.count && ![Self.comma, Self.closeObject, Self.closeArray, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
}

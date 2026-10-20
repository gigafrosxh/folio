import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum DatabaseClient {
    public static func clientPath(for driver: DatabaseDriver, locator: InterpreterLocator = .shared) -> String? {
        locator.find(driver.client)
    }

    public static func run(_ sql: String, on connection: DatabaseConnection, password: String?,
                           rowLimit: Int = 1000, timeout: TimeInterval = 30,
                           locator: InterpreterLocator = .shared) async throws -> QueryResult {
        guard let path = clientPath(for: connection.driver, locator: locator) else {
            throw DatabaseError.clientMissing(connection.driver.client)
        }
        let start = Date()
        var environment = locator.environment
        var input = sql + "\n;\n"
        var arguments: [String]
        let marker = "__folio_changes_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        switch connection.driver {
        case .sqlite:
            arguments = ["-bail", "-json", (connection.path as NSString).expandingTildeInPath]
            input += "SELECT changes() AS \(marker);\n"
        case .postgresql:
            arguments = ["-X", "-q", "-w", "-v", "ON_ERROR_STOP=1", "--csv", "-h", connection.host,
                         "-p", String(connection.port), "-U", connection.user, "-d", connection.database,
                         "-P", "null=" + marker, "-f", "-"]
            environment["PGPASSWORD"] = password
            environment["PGCONNECT_TIMEOUT"] = "5"
            environment["PGCLIENTENCODING"] = "UTF8"
        case .mysql:
            // XML supplies explicit result-set boundaries and SQL NULL markers; batch TSV does neither reliably.
            arguments = ["--batch", "--raw=false", "--column-names", "--xml", "-h", connection.host,
                         "-P", String(connection.port), "-u", connection.user,
                         "--default-character-set=utf8mb4", "--connect-timeout=5"]
            if !connection.database.isEmpty { arguments += ["--database=" + connection.database] }
            environment["MYSQL_PWD"] = password
        }
        let output = try await execute(path, arguments: arguments, input: input, environment: environment, timeout: timeout)
        var result: QueryResult
        switch connection.driver {
        case .sqlite:
            var parser = OrderedJSON(output)
            var sets = try parser.results()
            let changes = sets.last?.columns == [marker] ? sets.removeLast().rows.first?.first ?? nil : nil
            result = sets.last(where: { !$0.rows.isEmpty }) ?? QueryResult(message: changes.flatMap {
                (Int($0) ?? 0) > 0 ? "\($0) Zeilen geändert" : nil
            } ?? "Ausgeführt.")
        case .postgresql:
            result = try parseCSV(output, nullMarker: marker)
        case .mysql:
            result = try parseMySQLXML(output)
        }
        let limit = max(0, rowLimit)
        result.truncated = result.rows.count > limit
        result.rows = Array(result.rows.prefix(limit))
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    private static func execute(_ path: String, arguments: [String], input: String,
                                environment: [String: String], timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("folio-db-\(UUID())")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let urls = ["input", "output", "error"].map { directory.appendingPathComponent($0) }
                    try Data(input.utf8).write(to: urls[0])
                    try Data().write(to: urls[1]); try Data().write(to: urls[2])
                    let stdin = try FileHandle(forReadingFrom: urls[0])
                    let stdout = try FileHandle(forWritingTo: urls[1])
                    let stderr = try FileHandle(forWritingTo: urls[2])
                    defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: path)
                    process.arguments = arguments
                    process.environment = environment
                    process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
                    try process.run()
                    let deadline = Date().addingTimeInterval(timeout.isFinite ? max(0, timeout) : 30)
                    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                    if process.isRunning {
                        ServerDetector.terminateTree(process.processIdentifier)
                        process.waitUntilExit()
                        throw DatabaseError.timeout
                    }
                    process.waitUntilExit()
                    let error = try String(contentsOf: urls[2], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    let lower = error.lowercased()
                    let connectionError = ["could not connect", "connection refused", "access denied", "unable to open database",
                                           "can't connect", "connection to server", "password authentication failed", "unknown database",
                                           "could not translate host"].contains { lower.contains($0) }
                    if process.terminationStatus != 0 || lower.contains("error") || connectionError {
                        let message = error.isEmpty ? "Die Abfrage ist fehlgeschlagen (\(process.terminationStatus))." : error
                        throw connectionError ? DatabaseError.connectionFailed(message) : DatabaseError.queryFailed(message)
                    }
                    continuation.resume(returning: try String(contentsOf: urls[1], encoding: .utf8))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public static func testConnection(_ connection: DatabaseConnection, password: String?,
                                      locator: InterpreterLocator = .shared) async throws -> String {
        let result = try await run(connection.driver == .sqlite ? "SELECT sqlite_version();" : "SELECT version();",
                                   on: connection, password: password, locator: locator)
        return result.rows.first?.first.flatMap { $0 } ?? "Verbindung hergestellt."
    }

    public static func schema(of connection: DatabaseConnection, password: String?,
                              locator: InterpreterLocator = .shared) async throws -> [TableInfo] {
        let sql: String
        switch connection.driver {
        case .sqlite:
            sql = """
            SELECT NULL AS schema_name, m.name AS table_name, m.type AS table_type,
                   p.name AS column_name, p.type AS data_type, p.pk AS primary_key,
                   CASE WHEN p."notnull" = 1 OR p.pk > 0 THEN 0 ELSE 1 END AS nullable
            FROM sqlite_master m LEFT JOIN pragma_table_info(m.name) p
            WHERE m.type IN ('table','view') AND m.name NOT LIKE 'sqlite_%' ORDER BY m.name, p.cid;
            """
        case .postgresql:
            sql = """
            SELECT t.table_schema, t.table_name, t.table_type, c.column_name, c.data_type,
                   CASE WHEN EXISTS (SELECT 1 FROM information_schema.table_constraints k
                     JOIN information_schema.key_column_usage u ON u.constraint_catalog=k.constraint_catalog
                     AND u.constraint_schema=k.constraint_schema AND u.constraint_name=k.constraint_name
                     AND u.table_name=k.table_name
                     WHERE k.constraint_type='PRIMARY KEY' AND k.table_schema=t.table_schema
                     AND k.table_name=t.table_name AND u.column_name=c.column_name) THEN 1 ELSE 0 END AS primary_key,
                   CASE WHEN c.is_nullable='YES' THEN 1 ELSE 0 END AS nullable
            FROM information_schema.tables t LEFT JOIN information_schema.columns c
              ON c.table_schema=t.table_schema AND c.table_name=t.table_name
            WHERE t.table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY t.table_schema,t.table_name,c.ordinal_position;
            """
        case .mysql:
            sql = """
            SELECT t.table_schema,t.table_name,t.table_type,c.column_name,c.column_type,
                   CASE WHEN c.column_key='PRI' THEN 1 ELSE 0 END AS primary_key,
                   CASE WHEN c.is_nullable='YES' THEN 1 ELSE 0 END AS nullable
            FROM information_schema.tables t LEFT JOIN information_schema.columns c
              ON c.table_schema=t.table_schema AND c.table_name=t.table_name
            WHERE t.table_schema=DATABASE() ORDER BY t.table_schema,t.table_name,c.ordinal_position;
            """
        }
        let result = try await run(sql, on: connection, password: password, rowLimit: .max, locator: locator)
        var tables: [TableInfo] = []
        for row in result.rows where row.count == 7 {
            guard let name = row[1] else { continue }
            let schema = connection.driver == .sqlite ? nil : row[0]
            if tables.last?.name != name || tables.last?.schema != schema {
                tables.append(TableInfo(schema: schema, name: name, isView: row[2]?.lowercased() == "view"))
            }
            if let column = row[3] {
                tables[tables.count - 1].columns.append(ColumnInfo(name: column, type: row[4] ?? "",
                    isPrimaryKey: (Int(row[5] ?? "0") ?? 0) > 0, nullable: row[6] == "1"))
            }
        }
        return tables
    }

    static func parseMySQLXML(_ output: String) throws -> QueryResult {
        let delegate = MySQLXML()
        let cleaned = output.replacingOccurrences(of: "<\\?xml[^?]*\\?>", with: "", options: .regularExpression)
        let parser = XMLParser(data: Data(("<results>" + cleaned + "</results>").utf8))
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw DatabaseError.queryFailed("Die Datenbank-Ausgabe konnte nicht gelesen werden.") }
        return delegate.last ?? QueryResult(message: "Ausgeführt.")
    }

    // psql CSV has no explicit set boundaries: equal-width consecutive sets remain ambiguous.
    // A per-session NULL marker keeps single-column NULL rows distinct from blank separators.
    static func parseCSV(_ text: String, nullMarker: String? = nil) throws -> QueryResult {
        var records: [[String?]] = [], row: [String?] = [], field = ""
        var quoted = false, wasQuoted = false
        let chars = Array(text); var i = 0
        // With a NULL marker, an unquoted empty field is an empty string (psql writes '' unquoted).
        func endField() { row.append(field.isEmpty && !wasQuoted && nullMarker == nil ? nil : field); field = ""; wasQuoted = false }
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                else { quoted.toggle(); wasQuoted = true }
            } else if c == "," && !quoted { endField() }
            else if (c == "\n" || c == "\r\n" || c == "\r") && !quoted {
                if row.isEmpty && field.isEmpty && !wasQuoted { records.append([nil]) }   // blank line: set separator
                else { endField(); records.append(row) }
                row = []
            } else { field.append(c) }
            i += 1
        }
        guard !quoted else { throw DatabaseError.queryFailed("Ungültige CSV-Ausgabe.") }
        if !field.isEmpty || wasQuoted || !row.isEmpty { endField(); records.append(row) }
        var current: QueryResult?, last: QueryResult?
        for record in records {
            if record.count == 1 && record[0] == nil {
                if let value = current, !value.rows.isEmpty { last = value }; current = nil
            } else if current == nil || record.count != current?.columns.count {
                if let value = current, !value.rows.isEmpty { last = value }
                current = QueryResult(columns: record.map { $0 ?? "" })
            } else { current?.rows.append(record.map { value in value == nullMarker ? nil : value }) }
        }
        if let current, !current.rows.isEmpty { return current }
        return last ?? current ?? QueryResult(message: "Ausgeführt.")
    }
}

private struct OrderedJSON {
    let bytes: [UInt8]
    var index = 0
    init(_ text: String) { bytes = Array(text.utf8) }
    mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func consume(_ byte: UInt8) throws {
        whitespace()
        guard index < bytes.count, bytes[index] == byte else { throw DatabaseError.queryFailed("Ungültige JSON-Ausgabe.") }
        index += 1
    }
    mutating func scalar() throws -> String? {
        whitespace(); let start = index
        if index < bytes.count && bytes[index] == 34 {
            index += 1
            while index < bytes.count {
                let b = bytes[index]; index += 1
                if b == 92 { index += 1 } else if b == 34 { break }
            }
        } else {
            while index < bytes.count && ![44, 125, 93, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        guard index > start, index <= bytes.count else { throw DatabaseError.queryFailed("Ungültiger JSON-Wert.") }
        let data = Data(bytes[start..<index])
        let value = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        if value is NSNull { return nil }
        if let string = value as? String { return string }
        return String(decoding: data, as: UTF8.self)
    }
    mutating func results() throws -> [QueryResult] {
        var results: [QueryResult] = []
        whitespace()
        while index < bytes.count {
            try consume(91); whitespace()
            var result = QueryResult()
            while index < bytes.count && bytes[index] != 93 {
                try consume(123); whitespace()
                var keys: [String] = [], values: [String?] = []
                while index < bytes.count && bytes[index] != 125 {
                    keys.append(try scalar() ?? ""); try consume(58); values.append(try scalar()); whitespace()
                    if index < bytes.count && bytes[index] == 44 { index += 1 } else { break }
                }
                try consume(125)
                if result.rows.isEmpty { result.columns = keys }
                result.rows.append(values); whitespace()
                if index < bytes.count && bytes[index] == 44 { index += 1 } else { break }
            }
            try consume(93); results.append(result); whitespace()
        }
        return results
    }
}

private final class MySQLXML: NSObject, XMLParserDelegate {
    var last: QueryResult?
    private var current = QueryResult()
    private var row: [String?] = []
    private var text = ""
    private var inField = false
    private var isNull = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch elementName {
        case "resultset": current = QueryResult()
        case "row": row = []
        case "field":
            inField = true; text = ""; isNull = attributes["xsi:nil"] == "true"
            if current.rows.isEmpty { current.columns.append(attributes["name"] ?? "") }
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inField { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "field": row.append(isNull ? nil : text); inField = false
        case "row": current.rows.append(row)
        case "resultset": if !current.rows.isEmpty { last = current }
        default: break
        }
    }
}

import Foundation

/// Database systems a note can connect to. Queries run through the official command-line clients
/// (sqlite3, psql, mysql), found like interpreters via `InterpreterLocator`.
public enum DatabaseDriver: String, Codable, CaseIterable, Sendable, Identifiable {
    case sqlite, postgresql, mysql, mssql
    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .sqlite: return "SQLite"
        case .postgresql: return "PostgreSQL"
        case .mysql: return "MySQL / MariaDB"
        case .mssql: return "Microsoft SQL Server"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .sqlite: return 0
        case .postgresql: return 5432
        case .mysql: return 3306
        case .mssql: return 1433
        }
    }

    /// The command-line client used for this driver.
    public var client: String {
        switch self {
        case .sqlite: return "sqlite3"
        case .postgresql: return "psql"
        case .mysql: return "mysql"
        case .mssql: return "sqlcmd"
        }
    }
}

/// Connection settings stored in the note (never the password: that lives in the Keychain).
public struct DatabaseConnection: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var driver: DatabaseDriver
    /// SQLite: path to the database file.
    public var path: String
    public var host: String
    public var port: Int
    public var database: String
    public var user: String

    public init(id: UUID = UUID(), name: String = "", driver: DatabaseDriver = .sqlite, path: String = "",
                host: String = "localhost", port: Int? = nil, database: String = "", user: String = "") {
        self.id = id
        self.name = name
        self.driver = driver
        self.path = path
        self.host = host
        self.port = port ?? driver.defaultPort
        self.database = database
        self.user = user
    }

    /// Short label like "postgres@localhost:5432/shop" or "~/data.db".
    public var summary: String {
        switch driver {
        case .sqlite: return (path as NSString).abbreviatingWithTildeInPath
        default: return "\(user.isEmpty ? "" : user + "@")\(host):\(port)/\(database)"
        }
    }
}

/// The result of one statement (the last statement when several are sent).
public struct QueryResult: Sendable, Equatable {
    public var columns: [String]
    public var rows: [[String?]]          // nil = SQL NULL
    /// Message for statements without a result set, e.g. "3 Zeilen geändert" or the client's status line.
    public var message: String?
    public var duration: TimeInterval
    /// True when more rows existed than `rowLimit` and the list was cut.
    public var truncated: Bool

    public init(columns: [String] = [], rows: [[String?]] = [], message: String? = nil, duration: TimeInterval = 0, truncated: Bool = false) {
        self.columns = columns
        self.rows = rows
        self.message = message
        self.duration = duration
        self.truncated = truncated
    }
}

public struct TableInfo: Sendable, Equatable, Identifiable {
    public var schema: String?
    public var name: String
    public var isView: Bool
    public var columns: [ColumnInfo]
    public var id: String { (schema.map { $0 + "." } ?? "") + name }

    public init(schema: String? = nil, name: String, isView: Bool = false, columns: [ColumnInfo] = []) {
        self.schema = schema
        self.name = name
        self.isView = isView
        self.columns = columns
    }
}

public struct ColumnInfo: Sendable, Equatable {
    public var name: String
    public var type: String
    public var isPrimaryKey: Bool
    public var nullable: Bool

    public init(name: String, type: String, isPrimaryKey: Bool = false, nullable: Bool = true) {
        self.name = name
        self.type = type
        self.isPrimaryKey = isPrimaryKey
        self.nullable = nullable
    }
}

public enum DatabaseError: Error, LocalizedError, Equatable {
    case clientMissing(String)
    case connectionFailed(String)
    case queryFailed(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .clientMissing(let c): return "Der Datenbank-Client „\(c)“ ist nicht installiert (z. B. mit Homebrew: brew install \(c == "psql" ? "libpq" : c == "mysql" ? "mysql-client" : c == "sqlcmd" ? "sqlcmd" : c))."
        case .connectionFailed(let m): return "Verbindung fehlgeschlagen: \(m)"
        case .queryFailed(let m): return m
        case .timeout: return "Die Abfrage hat zu lange gedauert und wurde abgebrochen."
        }
    }
}

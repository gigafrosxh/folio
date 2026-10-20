import XCTest
import Foundation
import Darwin
@testable import FolioCore

final class DatabaseClientTests: XCTestCase {
    private var directories: [URL] = []
    private var servers: [Process] = []
    private var postgres: (String, String)?

    override func tearDownWithError() throws {
        if let (ctl, data) = postgres { _ = try? command(ctl, ["-D", data, "stop", "-m", "immediate", "-w"], timeout: 15) }
        for server in servers where server.isRunning {
            ServerDetector.terminateTree(server.processIdentifier)
            server.waitUntilExit()
        }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func temporaryDirectory() throws -> URL {
        // Short path under /tmp: Unix socket paths of the test servers must stay below ~100 characters.
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent("fdb-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private func binary(_ name: String) throws -> String {
        guard let path = InterpreterLocator.shared.find(name) else { throw XCTSkip("\(name) ist nicht installiert.") }
        return path
    }

    private func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DatabaseError.connectionFailed("Kein freier Port.") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard status == 0 else { throw DatabaseError.connectionFailed("Kein freier Port.") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    @discardableResult
    private func command(_ path: String, _ args: [String], timeout: TimeInterval = 30) throws -> String {
        let directory = try temporaryDirectory()
        let log = directory.appendingPathComponent("output")
        try Data().write(to: log)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        var env = InterpreterLocator.shared.environment
        // PostgreSQL refuses to start ("postmaster became multithreaded") without a valid locale.
        env["LC_ALL"] = "en_US.UTF-8"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            ServerDetector.terminateTree(process.processIdentifier); process.waitUntilExit()
            throw DatabaseError.timeout
        }
        process.waitUntilExit()
        let output = try String(contentsOf: log, encoding: .utf8)
        guard process.terminationStatus == 0 else { throw DatabaseError.queryFailed(output) }
        return output
    }

    private func roundTrip(_ connection: DatabaseConnection) async throws {
        let special = "Tab\tZeile\nKomma, ä 🎉 \\ Ende"
        let literal: String
        if connection.driver == .mysql {
            literal = "CONVERT(0x" + special.utf8.map { String(format: "%02x", $0) }.joined() + " USING utf8mb4)"
        } else { literal = "'" + special.replacingOccurrences(of: "'", with: "''") + "'" }
        let created = try await DatabaseClient.run("""
        CREATE TABLE folio_sample (id INTEGER PRIMARY KEY, title TEXT, score REAL);
        INSERT INTO folio_sample VALUES (1, \(literal), 1.5), (2, NULL, 2.25), (3, '', 3.5);
        """, on: connection, password: nil)
        XCTAssertNotNil(created.message)
        let result = try await DatabaseClient.run("SELECT title, id, score FROM folio_sample ORDER BY id;", on: connection, password: nil)
        XCTAssertEqual(result.columns, ["title", "id", "score"])
        XCTAssertEqual(result.rows, [[special, "1", "1.5"], [nil, "2", "2.25"], ["", "3", "3.5"]])
        let multiple = try await DatabaseClient.run("SELECT id FROM folio_sample; SELECT title, id FROM folio_sample WHERE id=2;", on: connection, password: nil)
        XCTAssertEqual(multiple.columns, ["title", "id"])
        XCTAssertEqual(multiple.rows, [[nil, "2"]])
        let limited = try await DatabaseClient.run("SELECT id FROM folio_sample ORDER BY id", on: connection, password: nil, rowLimit: 2)
        XCTAssertEqual(limited.rows, [["1"], ["2"]]); XCTAssertTrue(limited.truncated)
        let zero = try await DatabaseClient.run("SELECT id FROM folio_sample", on: connection, password: nil, rowLimit: 0)
        XCTAssertTrue(zero.rows.isEmpty); XCTAssertTrue(zero.truncated)
        do {
            _ = try await DatabaseClient.run("SELEC broken syntax", on: connection, password: nil)
            XCTFail("Syntaxfehler wurde nicht erkannt.")
        } catch DatabaseError.queryFailed(let message) { XCTAssertFalse(message.isEmpty) }
        _ = try await DatabaseClient.run("CREATE VIEW folio_view AS SELECT title FROM folio_sample", on: connection, password: nil)
        let tables = try await DatabaseClient.schema(of: connection, password: nil)
        let table = try XCTUnwrap(tables.first { $0.name == "folio_sample" })
        XCTAssertFalse(table.isView)
        XCTAssertEqual(table.columns.map(\.name), ["id", "title", "score"])
        XCTAssertTrue(table.columns[0].isPrimaryKey)
        XCTAssertFalse(table.columns[0].nullable)
        XCTAssertTrue(table.columns[1].nullable)
        XCTAssertTrue(table.columns.allSatisfy { !$0.type.isEmpty })
        XCTAssertEqual(tables.first { $0.name == "folio_view" }?.isView, true)
        if connection.driver == .postgresql { XCTAssertEqual(table.schema, "public") }
        if connection.driver == .mysql { XCTAssertEqual(table.schema, "test") }
        let version = try await DatabaseClient.testConnection(connection, password: nil)
        XCTAssertFalse(version.isEmpty)
    }

    func testSQLiteRoundTrip() async throws {
        _ = try binary("sqlite3")
        let directory = try temporaryDirectory()
        try await roundTrip(DatabaseConnection(driver: .sqlite, path: directory.appendingPathComponent("test.sqlite").path))
    }

    func testSQLiteLastNonemptyAndTimeout() async throws {
        _ = try binary("sqlite3")
        let connection = DatabaseConnection(driver: .sqlite, path: ":memory:")
        let result = try await DatabaseClient.run("SELECT 'ä' AS z, 1 AS a; SELECT 1 WHERE 0;", on: connection, password: nil)
        XCTAssertEqual(result.columns, ["z", "a"])
        XCTAssertEqual(result.rows, [["ä", "1"]])
        do {
            _ = try await DatabaseClient.run("WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n) SELECT sum(x) FROM n;", on: connection, password: nil, timeout: 0.05)
            XCTFail("Zeitlimit wurde nicht erkannt.")
        } catch DatabaseError.timeout { }
    }

    func testPostgreSQLRoundTrip() async throws {
        let initdb = try binary("initdb"), ctl = try binary("pg_ctl")
        _ = try binary("psql")
        let directory = try temporaryDirectory()
        let data = directory.appendingPathComponent("data").path
        let port = try freePort()
        do { try command(initdb, ["-D", data, "-A", "trust", "-U", "folio", "--encoding=UTF8", "--no-locale"]) }
        catch DatabaseError.queryFailed(let message) where message.contains("Operation not permitted") && message.contains("shared memory") {
            throw XCTSkip("Die Umgebung erlaubt PostgreSQL keinen gemeinsamen Speicher.")
        }
        postgres = (ctl, data)
        try command(ctl, ["-D", data, "-o", "-p \(port) -k /tmp -h 127.0.0.1", "-l", directory.appendingPathComponent("log").path, "start", "-w"])
        try await roundTrip(DatabaseConnection(driver: .postgresql, host: "127.0.0.1", port: port, database: "postgres", user: "folio"))
    }

    func testMySQLRoundTrip() async throws {
        let mysqld = try binary("mysqld")
        _ = try binary("mysql")
        let directory = try temporaryDirectory()
        let data = directory.appendingPathComponent("data").path
        let port = try freePort()
        do { try command(mysqld, ["--no-defaults", "--initialize-insecure", "--datadir=\(data)"], timeout: 30) }
        catch { throw XCTSkip("MySQL konnte nicht initialisiert werden: \(error)") }
        let server = Process()
        server.executableURL = URL(fileURLWithPath: mysqld)
        server.arguments = ["--no-defaults", "--datadir=\(data)", "--port=\(port)", "--socket=\(directory.path)/sock",
                            "--mysqlx=OFF", "--skip-networking=0", "--bind-address=127.0.0.1",
                            "--pid-file=\(directory.path)/server.pid", "--log-error=\(directory.path)/server.log"]
        server.standardInput = FileHandle.nullDevice; server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run(); servers.append(server)
        var connection = DatabaseConnection(driver: .mysql, host: "127.0.0.1", port: port, user: "root")
        let deadline = Date().addingTimeInterval(30)
        var ready = false
        while server.isRunning && Date() < deadline {
            if (try? await DatabaseClient.run("SELECT 1", on: connection, password: nil, timeout: 2)) != nil { ready = true; break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard ready else { throw XCTSkip("MySQL wurde nicht innerhalb von 30 Sekunden bereit.") }
        _ = try await DatabaseClient.run("CREATE DATABASE test", on: connection, password: nil)
        connection.database = "test"
        try await roundTrip(connection)
    }

    func testCSVQuotedFields() throws {
        let result = try DatabaseClient.parseCSV("name,value\n\"ä,🎉\nZeile\",\"a\"\"b\"\n,\"\"\n")
        XCTAssertEqual(result.columns, ["name", "value"])
        XCTAssertEqual(result.rows, [["ä,🎉\nZeile", "a\"b"], [nil, ""]])
    }

    func testMySQLXMLResultBoundariesAndNull() throws {
        let result = try DatabaseClient.parseMySQLXML("""
        <?xml version="1.0"?>
        <resultset statement="SELECT 1" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <row><field name="old">1</field></row></resultset>
        <?xml version="1.0"?>
        <resultset statement="SELECT title, id" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <row><field name="title">ä 🎉\tZeile\n,&amp;&lt;\\</field><field name="id">1</field></row>
        <row><field name="title" xsi:nil="true"/><field name="id">2</field></row>
        <row><field name="title"></field><field name="id">3</field></row>
        <row><field name="title">NULL</field><field name="id">4</field></row>
        </resultset>
        <resultset statement="SELECT 1 WHERE 0"/>
        """)
        XCTAssertEqual(result.columns, ["title", "id"])
        XCTAssertEqual(result.rows, [["ä 🎉\tZeile\n,&<\\", "1"], [nil, "2"], ["", "3"], ["NULL", "4"]])
    }

    func testCSVNullMarkerAndDifferentWidths() throws {
        let result = try DatabaseClient.parseCSV("old,other\n1,2\nvalue\nmarker\n\"\"\n", nullMarker: "marker")
        XCTAssertEqual(result.columns, ["value"])
        XCTAssertEqual(result.rows, [[nil], [""]])
    }
}

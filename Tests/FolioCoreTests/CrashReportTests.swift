import XCTest
@testable import FolioCore

final class CrashReportTests: XCTestCase {
    private let home = "/Users/geheim"

    private func ips(bundle: String = "de.daniel.folio", bug: Any = "309") throws -> Data {
        let header: [String: Any] = ["app_name": "Folio", "app_version": "1.3.0", "bundleID": bundle, "bug_type": bug,
                                     "os_version": "macOS 27.2 (27C1)", "timestamp": "2026-11-09 08:12:34.00 +0100",
                                     "incident_id": "ABCDEF01-2345-6789-ABCD-EF0123456789"]
        let payload: [String: Any] = [
            "cpuType": "ARM-64", "faultingThread": 0,
            "procPath": "/Users/geheim/Apps/Folio.app/Contents/MacOS/Folio",
            "exception": ["type": "EXC_BREAKPOINT", "signal": "SIGTRAP", "subtype": "bei /Users/geheim/Documents/Folio/Tagebuch.folio"],
            "termination": ["namespace": "SIGNAL", "indicator": "Trace/BPT trap: 5", "details": ["Geheimer Titel"]],
            "asi": ["Folio": ["Fatal error: Tagebuch geheimer Inhalt"]],
            "environment": ["SECRET=1"],
            "usedImages": [["name": "Folio", "path": "/Users/geheim/Apps/Folio.app/Contents/MacOS/Folio"],
                           ["name": "Geheim.dylib", "path": "/Users/geheim/lib/Geheim.dylib"],
                           ["name": "libswiftCore.dylib", "path": "/usr/lib/swift/libswiftCore.dylib"]],
            "threads": [["triggered": true, "frames": [
                ["imageIndex": 2, "imageOffset": 16, "symbol": "_assertionFailure"],
                ["imageIndex": 1, "imageOffset": 32, "symbol": "load(/Users/geheim/x)"],
                ["imageIndex": 0, "imageOffset": 64],
            ]]],
        ]
        var data = try JSONSerialization.data(withJSONObject: header)
        data.append(0x0A)
        data.append(try JSONSerialization.data(withJSONObject: payload))
        return data
    }

    func testReportHoldsOnlyAllowedFields() throws {
        guard case .report(let report) = CrashReports.parse(try ips(), id: "a", home: home, userName: "geheim") else {
            return XCTFail("kein Bericht")
        }
        let text = CrashReports.render([report])
        XCTAssertTrue(text.contains("EXC_BREAKPOINT"))
        XCTAssertTrue(text.contains("Folio 1.3.0"))
        XCTAssertTrue(text.contains("2026-11-09"))
        XCTAssertFalse(text.contains("08:12"))
        for secret in ["geheim", "Geheim", "Tagebuch", "SECRET", "ABCDEF01"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        XCTAssertTrue(text.contains("(andere Bibliothek)"))
        XCTAssertTrue(text.contains("libswiftCore.dylib"))
    }

    func testOtherAppsAndKindsAreIgnored() throws {
        XCTAssertEqual(CrashReports.parse(try ips(bundle: "com.other"), id: "a", home: home), .notAFolioCrash)
        XCTAssertEqual(CrashReports.parse(try ips(bug: "288"), id: "a", home: home), .notAFolioCrash)
        guard case .report = CrashReports.parse(try ips(bug: 309), id: "a", home: home) else { return XCTFail("bug_type als Zahl") }
    }

    func testDamagedFiles() throws {
        XCTAssertEqual(CrashReports.parse(Data("kein json".utf8), id: "a", home: home), .damaged)
        var header = try ips().prefix { $0 != 0x0A }
        header.append(contentsOf: Array("\n{kaputt".utf8))
        XCTAssertEqual(CrashReports.parse(Data(header), id: "a", home: home), .damaged)
    }

    func testScanFindsNewestFirstAndCountsDamaged() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("folio-crash-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try ips().write(to: folder.appendingPathComponent("Folio-1.ips"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("Folio-2.ips"))
        try ips().write(to: folder.appendingPathComponent("Safari-1.ips"))
        let scan = CrashReports.scan(folders: [folder, folder.appendingPathComponent("fehlt")])
        XCTAssertEqual(scan.reports.count, 1)
        XCTAssertEqual(scan.unreadable, 1)
    }

    func testScrubRemovesPathsAndAddresses() {
        func scrub(_ text: String) -> String { CrashReports.scrub(text, home: "/opt/heim", userName: "zz") }
        XCTAssertEqual(scrub("bei /Users/x/Meine Notizen/Tagebuch.folio"), "bei <Pfad>")
        XCTAssertEqual(scrub("/Volumes/Platte/b c\nweiter"), "<Pfad>\nweiter")
        XCTAssertEqual(scrub("/opt/heim/geheim datei"), "<Pfad>")
        XCTAssertEqual(scrub("mail@test.de 01234567-89AB-CDEF-0123-456789ABCDEF"), "<E-Mail> <ID>")
        XCTAssertEqual(scrub("/usr/lib/libswiftCore.dylib"), "/usr/lib/libswiftCore.dylib")
    }
}

import Foundation
import XCTest
@testable import Folio

/// Settings stored by older versions keep working in 1.0: missing keys get defaults, unknown or
/// broken values never reset the rest.
final class SettingsMigrationTests: XCTestCase {
    private func decode(_ json: String) throws -> ThemeSettings {
        try JSONDecoder().decode(ThemeSettings.self, from: Data(json.utf8))
    }

    func testEmptySettingsUseDefaults() throws {
        XCTAssertEqual(try decode("{}"), ThemeSettings())
    }

    func testOldSettingsKeepTheirValues() throws {
        // Shape of 0.12: no backups, quick access or resource limits yet; the old update opt-in key.
        let old = try decode("""
        {"appearance":"dark","accentHex":"#FF0000","editorFontSize":17,"codeThemeDark":"monokai",
         "runTimeout":60,"interpreterOverrides":{"python":"/opt/homebrew/bin/python3"},
         "libraryPath":"/Users/x/Notizen","checkUpdatesOnLaunch":false,"shortcuts":{"code":"ctrl+k"}}
        """)
        XCTAssertEqual(old.appearance, .dark)
        XCTAssertEqual(old.accentHex, "#FF0000")
        XCTAssertEqual(old.editorFontSize, 17)
        XCTAssertEqual(old.codeThemeDark, "monokai")
        XCTAssertEqual(old.runTimeout, 60)
        XCTAssertEqual(old.interpreterOverrides["python"], "/opt/homebrew/bin/python3")
        XCTAssertEqual(old.libraryPath, "/Users/x/Notizen")
        XCTAssertEqual(old.shortcuts["code"], "ctrl+k")
        XCTAssertTrue(old.askForUpdatesOnLaunch, "the old opt-in key does not switch update checks off")
        XCTAssertTrue(old.backupsEnabled)
        XCTAssertTrue(old.menuBarIcon)
        XCTAssertEqual(old.captureHotKey, "")
        XCTAssertEqual(old.trashRetentionDays, 30)
    }

    func testBrokenValueOnlyResetsThatValue() throws {
        let s = try decode(##"{"editorFontSize":"groß","appearance":"neon","accentHex":"#00FF00"}"##)
        XCTAssertEqual(s.editorFontSize, ThemeSettings().editorFontSize)
        XCTAssertEqual(s.appearance, ThemeSettings().appearance)
        XCTAssertEqual(s.accentHex, "#00FF00")
    }

    func testCurrentSettingsRoundTrip() throws {
        var s = ThemeSettings()
        s.captureHotKey = "off"
        s.backupFolder = "/Volumes/Backup"
        s.maxMemoryMB = 512
        XCTAssertEqual(try JSONDecoder().decode(ThemeSettings.self, from: JSONEncoder().encode(s)), s)
    }
}

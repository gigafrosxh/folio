import XCTest
@testable import FolioCore

final class UpdateCheckerTests: XCTestCase {
    func testSemVer() {
        XCTAssertTrue(UpdateChecker.isNewer("0.11.0", than: "0.10.3"))
        XCTAssertTrue(UpdateChecker.isNewer("v1.0.0", than: "0.99.9"))
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.5"))   // numeric, not string compare
        XCTAssertFalse(UpdateChecker.isNewer("0.11.0", than: "0.11.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9.0", than: "0.10.0"))
        XCTAssertFalse(UpdateChecker.isNewer("kaputt", than: "0.1.0"))
    }

    func testPrereleaseOrder() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0-rc.1", than: "0.20.4"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0-rc.2", than: "1.0.0-rc.1"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0-rc.10", than: "1.0.0-rc.2"), "numeric identifiers compare as numbers")
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "1.0.0-rc.3"), "the release outranks its candidates")
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0-rc.3", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0-rc.1", than: "1.0.0-rc.1"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0-rc.1", than: "1.0.0-beta.2"), "rc after beta")
        XCTAssertEqual(SemVer("v1.0.0-rc.1+build.7")?.description, "1.0.0-rc.1")
        XCTAssertNil(SemVer("1.0.0-"))
    }

    func testParseRelease() throws {
        let json = """
        {"tag_name":"v0.12.0","html_url":"https://github.com/gigafrosxh/folio/releases/tag/v0.12.0","body":"### Neu\\n- Update",
         "published_at":"2026-10-20T08:00:00Z",
         "assets":[{"name":"Folio-0.12.0-arm64.pkg","browser_download_url":"https://example.com/a.pkg"},
                   {"name":"Folio-0.12.0-arm64.dmg","browser_download_url":"https://example.com/a.dmg"}]}
        """
        let r = try UpdateChecker.parse(Data(json.utf8))
        XCTAssertEqual(r.version, "0.12.0")
        XCTAssertEqual(r.dmgURL?.absoluteString, "https://example.com/a.dmg")
        XCTAssertTrue(r.notes.contains("Update"))
        XCTAssertNotNil(r.published)
    }

    func testChangelogSections() {
        let md = """
        # Changelog

        ## [Unreleased]

        ## [0.12.3] – 2026-10-20

        ### Behoben
        - Update hing

        ## [0.12.2] – 2026-10-20

        ### Geändert
        - **Fortschritt** mit `MB`

        ## [0.12.1] – 2026-10-20
        - alt
        """
        let out = UpdateChecker.changelogSections(md, newerThan: "0.12.1")!
        XCTAssertTrue(out.hasPrefix("## Folio 0.12.3 · 2026-10-20"))
        XCTAssertTrue(out.contains("### Behoben\n- Update hing"))
        XCTAssertTrue(out.contains("## Folio 0.12.2"))
        XCTAssertFalse(out.contains("0.12.1"))
        XCTAssertFalse(out.contains("Unreleased"))
        XCTAssertNil(UpdateChecker.changelogSections(md, newerThan: "0.12.3"))
    }

    func testLiveLatestRelease() async throws {
        let r: ReleaseInfo
        do { r = try await UpdateChecker.latestRelease() } catch { throw XCTSkip("GitHub nicht erreichbar: \(error)") }
        XCTAssertNotNil(SemVer(r.version))
        XCTAssertNotNil(r.dmgURL)
    }
}

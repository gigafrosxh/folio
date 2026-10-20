import Foundation
import XCTest
@testable import Folio

/// The updater installs only correctly signed apps (#63) and replaces the app bundle only.
final class UpdateInstallTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-update-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func shell(_ exe: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// A tiny ad-hoc-signed app bundle with a resource file.
    private func makeApp(_ name: String, version: String) throws -> URL {
        let app = dir.appendingPathComponent("\(name).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: contents.appendingPathComponent("MacOS/Folio"))
        let plist: NSDictionary = ["CFBundleIdentifier": "de.daniel.folio", "CFBundleExecutable": "Folio",
                                   "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        try Data("render".utf8).write(to: contents.appendingPathComponent("Resources/render.html"))
        XCTAssertEqual(try shell("/usr/bin/codesign", ["--force", "--sign", "-", app.path]), 0)
        return app
    }

    func testSignedUpdateIsAccepted() throws {
        let current = try makeApp("Current", version: "1.0.0-rc.1")
        let new = try makeApp("New", version: "1.0.0")
        XCTAssertEqual(UpdateManager.signingInfo(new)?.valid, true)
        XCTAssertNoThrow(try UpdateManager.verifySignature(of: new, matching: current))
    }

    func testTamperedUpdateIsRejected() throws {
        let current = try makeApp("Current", version: "1.0.0-rc.1")
        let new = try makeApp("New", version: "1.0.0")
        try Data("<script>evil()</script>".utf8).write(to: new.appendingPathComponent("Contents/Resources/render.html"))
        XCTAssertEqual(UpdateManager.signingInfo(new)?.valid, false)
        XCTAssertThrowsError(try UpdateManager.verifySignature(of: new, matching: current))
    }

    func testUnsignedUpdateIsRejected() throws {
        let current = try makeApp("Current", version: "1.0.0-rc.1")
        let new = try makeApp("New", version: "1.0.0")
        XCTAssertEqual(try shell("/usr/bin/codesign", ["--remove-signature", new.path]), 0)
        XCTAssertThrowsError(try UpdateManager.verifySignature(of: new, matching: current))
    }

    /// Full path through a real disk image: the new bundle replaces the old one at the same place.
    func testReplaceFromDiskImage() throws {
        let current = try makeApp("Folio", version: "1.0.0-rc.1")
        let stage = dir.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let newApp = try makeApp("New", version: "1.0.0")
        try FileManager.default.moveItem(at: newApp, to: stage.appendingPathComponent("Folio.app"))
        let dmg = dir.appendingPathComponent("Folio-1.0.0-arm64.dmg")
        XCTAssertEqual(try shell("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "Folio", "-srcfolder", stage.path, "-format", "UDZO", dmg.path]), 0)

        XCTAssertThrowsError(try UpdateManager.replace(app: current, withAppIn: dmg, expectedVersion: "1.0.1", bundleID: "de.daniel.folio"), "wrong version is refused")
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path), "a refused update leaves the old app in place")

        XCTAssertEqual(try shell("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "Folio", "-srcfolder", stage.path, "-format", "UDZO", "-ov", dmg.path]), 0)
        let installed = try UpdateManager.replace(app: current, withAppIn: dmg, expectedVersion: "1.0.0", bundleID: "de.daniel.folio")
        let info = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(info?["CFBundleShortVersionString"] as? String, "1.0.0")
        XCTAssertEqual(UpdateManager.signingInfo(installed)?.valid, true, "the copied app keeps its signature")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dmg.path), "the download is removed")
        // The old test bundle went to the Trash; take it out again so the user's Trash stays clean.
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        for item in (try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent.hasPrefix("Folio") && NSDictionary(contentsOf: item.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String == "1.0.0-rc.1"
            && (try? FileManager.default.contentsOfDirectory(atPath: item.appendingPathComponent("Contents/Resources").path)) == ["render.html"] {
            try? FileManager.default.removeItem(at: item)
        }
    }
}

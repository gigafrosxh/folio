import AppKit
import Combine
import FolioCore

/// Checks GitHub for a newer Folio and installs it in place.
///
/// Installing replaces only the app bundle: notes live in the library folder (~/Documents/Folio by
/// default) and settings in the user defaults, so both stay untouched. The old app goes to the Trash.
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }

    /// The running app bundle, if Folio runs as an .app (not via `swift run`).
    var appBundleURL: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    func check(silently: Bool = false) {
        if case .downloading = state { return }
        if state == .installing { return }
        state = .checking
        Task {
            do {
                let release = try await UpdateChecker.latestRelease()
                lastChecked = Date()
                state = UpdateChecker.isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
            } catch {
                state = silently ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Installing

    func install(_ release: ReleaseInfo) {
        guard let dmgURL = release.dmgURL else { state = .failed("Das Release enthält kein Installationsabbild."); return }
        guard let app = appBundleURL else {
            state = .failed("Folio läuft nicht aus einer App (z. B. über swift run) und kann sich nicht selbst ersetzen.")
            return
        }
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            state = .failed("Keine Schreibrechte für \(app.deletingLastPathComponent().path). Lade das Update auf GitHub herunter.")
            return
        }
        NoteStore.shared.currentDocument?.saveNow()
        state = .downloading(0)
        Task {
            do {
                let dmg = try await download(dmgURL)
                state = .installing
                let newApp = try await Task.detached { try Self.replace(app: app, withAppIn: dmg, expectedVersion: release.version) }.value
                relaunch(newApp)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func download(_ url: URL) async throws -> URL {
        let delegate = ProgressDelegate { [weak self] p in
            Task { @MainActor in self?.state = .downloading(p) }
        }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (tmp, response) = try await session.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InstallError.step("Download fehlgeschlagen.") }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("Folio-Update-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: tmp, to: target)
        return target
    }

    enum InstallError: Error, LocalizedError {
        case step(String)
        var errorDescription: String? { if case .step(let m) = self { return m }; return nil }
    }

    /// Mounts the disk image, checks the new app, puts the old one in the Trash and moves the new one in.
    nonisolated static func replace(app: URL, withAppIn dmg: URL, expectedVersion: String) throws -> URL {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: dmg) }
        let mountPoint = fm.temporaryDirectory.appendingPathComponent("folio-update-mnt-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path])
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
            try? fm.removeItem(at: mountPoint)
        }
        let mounted = mountPoint.appendingPathComponent("Folio.app")
        guard let info = NSDictionary(contentsOf: mounted.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier ?? "de.daniel.folio" else {
            throw InstallError.step("Das heruntergeladene Abbild enthält keine gültige Folio-App.")
        }
        if let v = info["CFBundleShortVersionString"] as? String, v != expectedVersion {
            throw InstallError.step("Unerwartete Version im Download (\(v) statt \(expectedVersion)).")
        }
        // Copy next to the old app first, so a failure never leaves the user without Folio.
        let staged = app.deletingLastPathComponent().appendingPathComponent(".Folio-update-\(UUID().uuidString.prefix(8)).app")
        try run("/usr/bin/ditto", [mounted.path, staged.path])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        do {
            try fm.trashItem(at: app, resultingItemURL: nil)
        } catch {
            try? fm.removeItem(at: staged)
            throw InstallError.step("Die alte Version konnte nicht entfernt werden: \(error.localizedDescription)")
        }
        try fm.moveItem(at: staged, to: app)
        return app
    }

    @discardableResult
    nonisolated private static func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw InstallError.step("\((exe as NSString).lastPathComponent) fehlgeschlagen: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    /// Starts the new app after this one has quit.
    private func relaunch(_ app: URL) {
        let script = "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"\(app.path)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try? p.run()
        NSApp.terminate(nil)
    }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

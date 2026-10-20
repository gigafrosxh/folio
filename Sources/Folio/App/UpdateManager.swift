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
        /// Download and installation: overall fraction 0…1, the current step and a detail line (MB).
        case installing(UpdateProgress)
        case failed(String)
    }

    struct UpdateProgress: Equatable {
        var fraction: Double
        var step: String
        var detail: String = ""
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    /// Changes of all versions newer than the installed one (Markdown), shown in the update window.
    @Published private(set) var changelog: String?

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }

    /// The running app bundle, if Folio runs as an .app (not via `swift run`).
    var appBundleURL: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    func check(silently: Bool = false) {
        if case .installing = state { return }
        state = .checking
        Task {
            do {
                let release = try await UpdateChecker.latestRelease()
                lastChecked = Date()
                if UpdateChecker.isNewer(release.version, than: currentVersion) {
                    changelog = await UpdateChecker.changelog(since: currentVersion)
                    state = .available(release)
                } else {
                    state = .upToDate
                }
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
        NoteStore.shared.saveAll()
        // One bar for the whole update: download 0–80 %, then check, install and restart.
        state = .installing(UpdateProgress(fraction: 0, step: "Lade Folio \(release.version) herunter …"))
        Task {
            do {
                let dmg = try await download(dmgURL, version: release.version)
                state = .installing(UpdateProgress(fraction: 0.82, step: "Prüfe die neue Version …"))
                let report: @Sendable (Double, String) -> Void = { fraction, step in
                    Task { @MainActor in UpdateManager.shared.state = .installing(UpdateProgress(fraction: fraction, step: step)) }
                }
                let newApp = try await Task.detached {
                    try Self.replace(app: app, withAppIn: dmg, expectedVersion: release.version, report: report)
                }.value
                state = .installing(UpdateProgress(fraction: 1, step: "Starte Folio \(release.version) neu …"))
                try? await Task.sleep(for: .milliseconds(600))
                relaunch(newApp)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Downloads with a data task so progress (bytes received) is reported reliably.
    private func download(_ url: URL, version: String) async throws -> URL {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("Folio-Update-\(UUID().uuidString).dmg")
        let delegate = DownloadDelegate(target: target) { received, total in
            Task { @MainActor in
                let fraction = total > 0 ? Double(received) / Double(total) : 0
                let mb = { (b: Int64) in String(format: "%.1f MB", Double(b) / 1_048_576) }
                UpdateManager.shared.state = .installing(UpdateProgress(
                    fraction: fraction * 0.8, step: "Lade Folio \(version) herunter …",
                    detail: total > 0 ? "\(mb(received)) von \(mb(total)) · \(Int(fraction * 100)) %" : mb(received)))
            }
        }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { cont in
            delegate.continuation = cont
            session.downloadTask(with: url).resume()
        }
    }

    enum InstallError: Error, LocalizedError {
        case step(String)
        var errorDescription: String? { if case .step(let m) = self { return m }; return nil }
    }

    /// Mounts the disk image, checks the new app, puts the old one in the Trash and moves the new one in.
    nonisolated static func replace(app: URL, withAppIn dmg: URL, expectedVersion: String,
                                    bundleID: String = Bundle.main.bundleIdentifier ?? "de.daniel.folio",
                                    report: @Sendable (Double, String) -> Void = { _, _ in }) throws -> URL {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: dmg) }
        let mountPoint = fm.temporaryDirectory.appendingPathComponent("folio-update-mnt-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path])
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
            try? fm.removeItem(at: mountPoint)
        }
        report(0.86, "Prüfe die neue Version …")
        let mounted = mountPoint.appendingPathComponent("Folio.app")
        guard let info = NSDictionary(contentsOf: mounted.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID else {
            throw InstallError.step("Das heruntergeladene Abbild enthält keine gültige Folio-App.")
        }
        if let v = info["CFBundleShortVersionString"] as? String, v != expectedVersion {
            throw InstallError.step("Unerwartete Version im Download (\(v) statt \(expectedVersion)).")
        }
        try verifySignature(of: mounted, matching: app)
        // Copy next to the old app first, so a failure never leaves the user without Folio.
        report(0.9, "Kopiere die neue Version …")
        let staged = app.deletingLastPathComponent().appendingPathComponent(".Folio-update-\(UUID().uuidString.prefix(8)).app")
        try run("/usr/bin/ditto", [mounted.path, staged.path])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        report(0.96, "Ersetze die alte Version …")
        do {
            try fm.trashItem(at: app, resultingItemURL: nil)
        } catch {
            try? fm.removeItem(at: staged)
            throw InstallError.step("Die alte Version konnte nicht entfernt werden: \(error.localizedDescription)")
        }
        try fm.moveItem(at: staged, to: app)
        return app
    }

    /// The new app must have an intact signature, and once Folio is signed with a Developer ID (#63) the
    /// update must come from the same team: a tampered or foreign download is never installed.
    nonisolated static func verifySignature(of new: URL, matching current: URL) throws {
        guard let newInfo = signingInfo(new), newInfo.valid else {
            throw InstallError.step("Die Signatur der heruntergeladenen Version ist ungültig.")
        }
        if let team = signingInfo(current)?.team, newInfo.team != team {
            throw InstallError.step("Die heruntergeladene Version ist nicht vom selben Entwickler signiert.")
        }
    }

    nonisolated static func signingInfo(_ app: URL) -> (valid: Bool, team: String?)? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        let valid = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        return (valid, team)
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
        // An open sheet (like the update window itself) can make AppKit cancel a normal quit, which left
        // the new version waiting forever. Save and clean up ourselves, then quit for sure.
        NoteStore.shared.saveAll()
        RunManager.shared.stopAll()
        TerminalSession.closeAll()
        KernelManager.shared.shutdownAll()
        LSPCompleter.shared.shutdownAll()
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let target: URL
    let onProgress: @Sendable (Int64, Int64) -> Void
    var continuation: CheckedContinuation<URL, Error>?

    init(target: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.target = target
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            continuation?.resume(throwing: UpdateManager.InstallError.step("Download fehlgeschlagen (HTTP \(status))."))
            continuation = nil
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: target)
            continuation?.resume(returning: target)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: UpdateManager.InstallError.step("Download fehlgeschlagen: \(error.localizedDescription)"))
        continuation = nil
    }
}

import Foundation

/// One Folio crash from the system's diagnostic reports, reduced to fields that hold no personal data (#61).
public struct CrashReport: Hashable, Sendable, Identifiable {
    public struct Frame: Hashable, Sendable {
        public var image: String
        public var offset: Int
        public var symbol: String?
    }

    public var id: String
    /// Full timestamp, only for sorting; the report itself shows the day.
    public var timestamp: String
    public var process: String
    public var appVersion: String
    public var systemVersion: String
    public var architecture: String
    public var exception: String
    public var termination: String?
    public var frames: [Frame]
    public var exceptionFrames: [Frame]
}

/// Finds Folio's crashes and writes a report without note contents, paths or machine identifiers. Allow-list
/// parsing: only the fields named here are ever read, and every string that is kept passes through `scrub`.
/// Nothing leaves the Mac unless the person saves or copies the text.
public enum CrashReports {
    public static let bundleID = "de.daniel.folio"
    private static let maxFileSize = 8 * 1024 * 1024
    private static let maxFrames = 40

    public struct Scan: Sendable {
        public var reports: [CrashReport] = []
        /// Reports from Folio that could not be understood.
        public var unreadable = 0
    }

    public static func defaultFolders(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        if let override = environment["FOLIO_CRASH_REPORTS"] { return [URL(fileURLWithPath: override, isDirectory: true)] }
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        return [logs, logs.appendingPathComponent("Retired", isDirectory: true)]
    }

    public static func scan(folders: [URL] = defaultFolders(), limit: Int = 10) -> Scan {
        var scan = Scan()
        let fm = FileManager.default
        for folder in folders {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            for file in files where file.pathExtension == "ips" && mentionsFolio(file.lastPathComponent) {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= maxFileSize, let data = try? Data(contentsOf: file) else {
                    scan.unreadable += 1
                    continue
                }
                switch parse(data, id: file.lastPathComponent) {
                case .report(let report): scan.reports.append(report)
                case .damaged: scan.unreadable += 1
                case .notAFolioCrash: break
                }
            }
        }
        scan.reports.sort { $0.timestamp > $1.timestamp }
        scan.reports = Array(scan.reports.prefix(limit))
        return scan
    }

    private static func mentionsFolio(_ fileName: String) -> Bool { fileName.lowercased().hasPrefix("folio") }

    public enum ParseResult: Hashable, Sendable {
        case report(CrashReport)
        case notAFolioCrash
        case damaged
    }

    /// `.ips` files are one line of JSON (header) followed by a JSON document (payload).
    public static func parse(_ data: Data, id: String, home: String = NSHomeDirectory(), userName: String = NSUserName()) -> ParseResult {
        guard let newline = data.firstIndex(of: 0x0A),
              let header = (try? JSONSerialization.jsonObject(with: data[data.startIndex..<newline])) as? [String: Any] else {
            return .damaged
        }
        let bundle = header["bundleID"] as? String
        let name = header["app_name"] as? String ?? ""
        let isFolio = bundle.map { $0 == bundleID || $0.hasPrefix(bundleID + ".") } ?? (name == "Folio")
        guard isFolio else { return .notAFolioCrash }
        guard "\(header["bug_type"] ?? "")" == "309" else { return .notAFolioCrash }
        guard let payload = (try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...])) as? [String: Any] else {
            return .damaged
        }
        func clean(_ value: Any?) -> String { (value as? String).map { scrub($0, home: home, userName: userName) } ?? "" }

        let images = payload["usedImages"] as? [[String: Any]] ?? []
        func frames(_ raw: Any?) -> [CrashReport.Frame] {
            ((raw as? [[String: Any]]) ?? []).prefix(maxFrames).map { frame in
                let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil }
                return CrashReport.Frame(image: imageName(image, home: home, userName: userName),
                                         offset: frame["imageOffset"] as? Int ?? 0,
                                         symbol: (frame["symbol"] as? String).map { scrub($0, home: home, userName: userName) })
            }
        }

        let exception = payload["exception"] as? [String: Any] ?? [:]
        let exceptionText = [clean(exception["type"]), clean(exception["signal"]), clean(exception["subtype"])]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let termination = payload["termination"] as? [String: Any]
        let terminationText = [clean(termination?["namespace"]), clean(termination?["indicator"])]
            .filter { !$0.isEmpty }.joined(separator: " · ")

        let threads = payload["threads"] as? [[String: Any]] ?? []
        let faulting = (payload["faultingThread"] as? Int).flatMap { threads.indices.contains($0) ? threads[$0] : nil }
            ?? threads.first { $0["triggered"] as? Bool == true }
        guard !exceptionText.isEmpty || faulting != nil else { return .damaged }

        let timestamp = header["timestamp"] as? String ?? payload["captureTime"] as? String ?? ""
        return .report(CrashReport(id: id, timestamp: timestamp, process: clean(header["app_name"]),
                                   appVersion: clean(header["app_version"]), systemVersion: clean(header["os_version"]),
                                   architecture: clean(payload["cpuType"]), exception: exceptionText,
                                   termination: terminationText.isEmpty ? nil : terminationText,
                                   frames: frames(faulting?["frames"]),
                                   exceptionFrames: frames(payload["lastExceptionBacktrace"])))
    }

    /// Images from outside the system and the app keep no name: a plug-in's name can say something about its owner.
    private static func imageName(_ image: [String: Any]?, home: String, userName: String) -> String {
        guard let image, let name = image["name"] as? String else { return "?" }
        let path = image["path"] as? String ?? ""
        let known = path.hasPrefix("/System/") || path.hasPrefix("/usr/lib/") || name.hasPrefix("Folio")
        return known ? scrub(name, home: home, userName: userName) : "(andere Bibliothek)"
    }

    // A user path may contain spaces and ends a file name nobody should see, so everything after its start goes.
    private static let patterns: [(NSRegularExpression, String)] = [
        (#"(?:/private)?/var/folders/[^\n]*"#, "<Pfad>"),
        (#"/Users/[^\n]*"#, "<Pfad>"),
        (#"/Volumes/[^\n]*"#, "<Pfad>"),
        (#"file:/[^\n]*"#, "<Pfad>"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<E-Mail>"),
        (#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#, "<ID>"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// Removes paths, names, addresses and identifiers from a kept string.
    public static func scrub(_ text: String, home: String = NSHomeDirectory(), userName: String = NSUserName()) -> String {
        var out = text
        if home.count > 1, let range = out.range(of: home) {
            let lineEnd = out[range.lowerBound...].firstIndex(of: "\n") ?? out.endIndex
            out.replaceSubrange(range.lowerBound..<lineEnd, with: "<Pfad>")
        }
        for (regex, replacement) in patterns {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                 withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        }
        if userName.count >= 3 {
            out = out.replacingOccurrences(of: userName, with: "<Name>", options: [.caseInsensitive])
        }
        return out
    }

    /// The text the person sees before saving or copying it.
    public static func render(_ reports: [CrashReport]) -> String {
        var lines = ["Folio-Absturzbericht", "",
                     "Enthält nur technische Angaben. Keine Notizinhalte, Titel, Datei- oder Benutzernamen und keine Geräte-IDs."]
        if reports.isEmpty { lines += ["", "Keine Abstürze gefunden."] }
        for (index, report) in reports.enumerated() {
            lines += ["", "## Absturz \(index + 1) von \(reports.count)",
                      "Datum: \(report.timestamp.prefix(10))",
                      "Programm: \(report.process) \(report.appVersion)",
                      "System: \(report.systemVersion) (\(report.architecture))",
                      "Fehler: \(report.exception)"]
            if let termination = report.termination { lines.append("Beendet: \(termination)") }
            if !report.exceptionFrames.isEmpty { lines += ["", "Ausnahme:"] + report.exceptionFrames.enumerated().map(frameLine) }
            if !report.frames.isEmpty { lines += ["", "Abgestürzter Thread:"] + report.frames.enumerated().map(frameLine) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func frameLine(_ item: (offset: Int, element: CrashReport.Frame)) -> String {
        let frame = item.element
        return "\(item.offset)\t\(frame.image)\t+\(frame.offset)" + (frame.symbol.map { "\t\($0)" } ?? "")
    }
}

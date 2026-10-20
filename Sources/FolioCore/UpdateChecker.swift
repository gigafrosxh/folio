import Foundation

/// A semantic version like 0.11.0 or 1.0.0-rc.1 (a leading "v" is ignored). A pre-release sorts before
/// the release it leads up to: 1.0.0-rc.1 < 1.0.0-rc.2 < 1.0.0.
public struct SemVer: Comparable, Sendable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int
    /// Pre-release identifiers ("rc", "1"); empty for a release.
    public var prerelease: [String] = []

    public init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        t = String(t.split(separator: "+", maxSplits: 1).first ?? "")   // build metadata does not count
        let parts0 = t.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let core = parts0.first ?? t
        let parts = core.split(separator: ".").map { Int($0) }
        guard parts.count >= 2, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        major = parts[0]!
        minor = parts[1]!
        patch = parts.count == 3 ? parts[2]! : 0
        if parts0.count == 2 {
            prerelease = parts0[1].split(separator: ".").map(String.init)
            guard !prerelease.isEmpty, prerelease.allSatisfy({ !$0.isEmpty }) else { return nil }
        }
    }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) { return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
        // A release outranks its pre-releases.
        if a.prerelease.isEmpty != b.prerelease.isEmpty { return !a.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (.some, nil): return true          // numbers sort before words
            case (nil, .some): return false
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }

    public static func == (a: SemVer, b: SemVer) -> Bool {
        (a.major, a.minor, a.patch) == (b.major, b.minor, b.patch) && a.prerelease == b.prerelease
    }

    public var description: String { "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: ".")) }
}

/// The newest published release on GitHub.
public struct ReleaseInfo: Sendable, Equatable {
    public var version: String
    public var notes: String
    public var pageURL: URL
    public var dmgURL: URL?
    public var published: Date?
}

public enum UpdateChecker {
    public static let repository = "gigafrosxh/folio"
    public static var latestReleaseAPI: URL { URL(string: "https://api.github.com/repos/\(repository)/releases/latest")! }

    public enum UpdateError: Error, LocalizedError {
        case network(String)
        case noRelease
        case badResponse

        public var errorDescription: String? {
            switch self {
            case .network(let m): return "GitHub ist nicht erreichbar: \(m)"
            case .noRelease: return "Auf GitHub gibt es noch kein Release."
            case .badResponse: return "Die Antwort von GitHub konnte nicht gelesen werden."
            }
        }
    }

    /// Reads GitHub's "latest release" JSON; picks the arm64 disk image.
    public static func parse(_ data: Data) throws -> ReleaseInfo {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { throw UpdateError.badResponse }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.hasSuffix("-arm64.dmg") == true }
            ?? assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
        let formatter = ISO8601DateFormatter()
        return ReleaseInfo(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                           notes: stripFooter(json["body"] as? String ?? ""),
                           pageURL: page,
                           dmgURL: (dmg?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                           published: (json["published_at"] as? String).flatMap(formatter.date(from:)))
    }

    public static func latestRelease(session: URLSession = .shared) async throws -> ReleaseInfo {
        var request = URLRequest(url: latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Folio-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw UpdateError.network(error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw UpdateError.noRelease }
        // The anonymous API allows 60 requests per hour; when that is used up, read the release page instead.
        if status == 403 || status == 429 { return try await latestFromReleasePage(session: session) }
        guard status == 200 else { throw UpdateError.network("HTTP \(status)") }
        return try parse(data)
    }

    /// Without the API: github.com/…/releases/latest redirects to …/tag/vX.Y.Z, and the assets follow a fixed name.
    static func latestFromReleasePage(session: URLSession) async throws -> ReleaseInfo {
        let url = URL(string: "https://github.com/\(repository)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        let response: URLResponse
        do { (_, response) = try await session.data(for: request) } catch { throw UpdateError.network(error.localizedDescription) }
        guard let final = response.url, final.path.contains("/tag/") else { throw UpdateError.noRelease }
        let tag = final.lastPathComponent
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard SemVer(version) != nil else { throw UpdateError.badResponse }
        return ReleaseInfo(version: version, notes: "", pageURL: final,
                           dmgURL: URL(string: "https://github.com/\(repository)/releases/download/\(tag)/Folio-\(version)-arm64.dmg"),
                           published: nil)
    }

    /// The changes of every version newer than `current`, newest first, taken from CHANGELOG.md on GitHub
    /// (one "## [X.Y.Z] – date" section per version, Markdown kept as written).
    public static func changelog(since current: String, session: URLSession = .shared) async -> String? {
        let url = URL(string: "https://raw.githubusercontent.com/\(repository)/main/CHANGELOG.md")!
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return changelogSections(String(decoding: data, as: UTF8.self), newerThan: current)
    }

    public static func changelogSections(_ markdown: String, newerThan current: String) -> String? {
        var sections: [(SemVer, String, [String])] = []
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## [") {
                let inside = line.dropFirst(4).prefix { $0 != "]" }
                if let v = SemVer(String(inside)) {
                    let date = line.components(separatedBy: "] ").dropFirst().joined(separator: "] ").trimmingCharacters(in: CharacterSet(charactersIn: "–- "))
                    sections.append((v, date, []))
                } else {
                    sections.append((SemVer("0.0.0")!, "", []))   // [Unreleased]: skipped below
                }
                continue
            }
            if !sections.isEmpty { sections[sections.count - 1].2.append(line) }
        }
        let newer = sections.filter { isNewer($0.0.description, than: current) }.sorted { $0.0 > $1.0 }
        guard !newer.isEmpty else { return nil }
        return newer.map { v, date, lines in
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            // Version headings become level 2, the section headings inside them level 3.
            return "## Folio \(v)\(date.isEmpty ? "" : " · " + date)\n\n" + body
        }.joined(separator: "\n\n")
    }

    /// Release bodies end with a "---" block about installing; inside the app that is noise.
    public static func stripFooter(_ body: String) -> String {
        if let r = body.range(of: "\n---\n") { return String(body[..<r.lowerBound]) }
        return body
    }

    /// True when `latest` is newer than `current`.
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let l = SemVer(latest), let c = SemVer(current) else { return false }
        return c < l
    }
}

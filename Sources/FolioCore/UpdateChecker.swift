import Foundation

/// A semantic version like 0.11.0 (a leading "v" is ignored).
public struct SemVer: Comparable, Sendable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int

    public init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        let core = t.split(separator: "-").first.map(String.init) ?? t
        let parts = core.split(separator: ".").map { Int($0) }
        guard parts.count >= 2, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        major = parts[0]!
        minor = parts[1]!
        patch = parts.count == 3 ? parts[2]! : 0
    }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
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
                           notes: json["body"] as? String ?? "",
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
        guard status == 200 else { throw UpdateError.network("HTTP \(status)") }
        return try parse(data)
    }

    /// True when `latest` is newer than `current`.
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let l = SemVer(latest), let c = SemVer(current) else { return false }
        return c < l
    }
}
